// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ArtCoinsToken} from "../ArtCoinsToken.sol";

import {IArtCoinsFactory} from "../interfaces/IArtCoinsFactory.sol";
import {IArtCoinsFeeEscrow} from "../interfaces/IArtCoinsFeeEscrow.sol";

import {IArtCoinsMevModule} from "../interfaces/IArtCoinsMevModule.sol";
import {IArtCoinsMevModuleBase} from "../interfaces/IArtCoinsMevModuleBase.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks, IHooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {IArtCoinsPoolExtension} from "./interfaces/IArtCoinsPoolExtension.sol";
import {IArtCoinsPoolExtensionAllowlist} from "./interfaces/IArtCoinsPoolExtensionAllowlist.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IArtCoinsHook} from "../interfaces/IArtCoinsHook.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BalanceDelta, add, sub, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";

/// @title  ArtCoinsHook
/// @notice The canonical ArtCoins Uniswap v4 hook. Abstract base for concrete
///         hook variants (`ArtCoinsHookStaticFee`, and dynamic-fee variants).
///         Coordinates fee enforcement, MEV module dispatch, sniper-extra fee
///         routing, and per-pool extensions for ArtCoins-deployed pools.
///
/// @dev    Behavioral notes:
///           1. `_initializePool` accepts `pairedToken == address(0)` —
///              native-ETH pool pairing is allowed.
///           2. `_sniperExtraFeeClaim` routes native-ETH sniper-extra fees
///              through `feeEscrow.storeFeesNative` instead of pushing ETH
///              directly to the recipient via `poolManager.take`, so a locked,
///              non-payable sniper-fee recipient on a native-ETH pool cannot
///              brick swaps.
///           3. There is no per-swap LP-locker fee claim. Distribution is
///              pull-based: `lpLocker.collectRewards(token)` is permissionless
///              and can be called by any keeper when accrued fees justify the
///              gas, so pools stay cheap to route through.
///           4. This base hook adds no protocol-fee path of its own: through
///              the base alone the trader pays exactly the pool fee. Inheriting
///              variants MAY add a hook-level skim on top of the pool fee (see
///              the deployed contract's own documentation for whether it does);
///              the base imposes no such skim.
///
///         Inheriting hooks override `_setFee` and `_initializeFeeData` to
///         specialize fee logic.
abstract contract ArtCoinsHook is BaseHook, IArtCoinsHook {
    using TickMath for int24;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;
    using StateLibrary for *;

    /// @notice Maximum normal LP fee (10%).
    uint24 public constant MAX_LP_FEE = 100_000;
    /// @notice Maximum LP fee MEV modules may set (99%).
    uint24 public constant MAX_MEV_LP_FEE = 990_000;
    /// @notice Uniswap fee denominator (1,000,000 = 100%). Used by the
    ///         sniper-extra fee math and the `_afterSwap` delta recomposition.
    int128 public constant FEE_DENOMINATOR = 1_000_000;

    /// @notice The factory authorized to call factory-only paths.
    address public immutable factory;
    /// @notice Allowlist of approved pool extensions.
    IArtCoinsPoolExtensionAllowlist public immutable poolExtensionAllowlist;
    /// @notice WETH address.
    address public immutable weth;
    /// @notice Fee escrow. Used by `_sniperExtraFeeClaim` to route native-ETH
    ///         sniper-extra fees through a push-safe path. The escrow must
    ///         allowlist this hook as a depositor (`escrow.addDepositor(hook)`)
    ///         at deploy time so `storeFeesNative` calls succeed.
    IArtCoinsFeeEscrow public immutable feeEscrow;

    /// @notice Whether ArtCoins is `token0` for a given pool.
    mapping(PoolId => bool) public artCoinIsToken0;
    /// @notice LP locker bound to each pool.
    mapping(PoolId => address) public locker;

    /// @notice Maximum window between pool creation and MEV module activation (15 minutes).
    uint256 public constant MAX_MEV_MODULE_DELAY = 15 minutes;
    /// @notice MEV module bound to each pool.
    mapping(PoolId => address) public mevModule;
    /// @notice Whether the MEV module is currently active for each pool.
    mapping(PoolId => bool) public mevModuleEnabled;
    /// @notice Block timestamp at which each pool was initialized.
    mapping(PoolId => uint256) public poolCreationTimestamp;

    /// @notice Pool extension contract bound to each pool (zero if none).
    mapping(PoolId => address) public poolExtension;
    /// @notice Whether the pool extension's post-locker setup has completed.
    mapping(PoolId => bool) public poolExtensionSetup;
    /// @notice Whether the pool's extension slot has been permanently locked
    ///         by the token admin via `lockPoolExtension`. Once true, the
    ///         extension can no longer be swapped — credibility lever for
    ///         projects that want to commit to a specific renderer-data shape.
    mapping(PoolId => bool) public poolExtensionLocked;

    // ─── sniper-extra fee path (independent of locker reward split) ────────
    //
    // The bound MEV module can signal an "extra" ppm on top of the pool's base
    // LP fee for the next swap (via `mevModuleSetSniperFee`). The hook skims
    // that extra from the swap's input currency in `_beforeSwap`, accrues it
    // as PoolManager claim tokens, and lazily flushes it to the per-pool
    // `sniperFeeRecipient` on the start of the NEXT swap (settlement timing
    // forces lazy flush — the input currency hasn't been settled yet at
    // beforeSwap time). The pool's LP fee is NOT changed by this path, so the
    // locker reward split continues to receive only the base pool fee.

    /// @notice Per-pool destination for sniper-extra fees (e.g. BurnRouter for
    ///         LAYER). Zero means the path is disabled and any signaled extra
    ///         is silently skipped.
    mapping(PoolId => address) public sniperFeeRecipient;
    /// @notice True if the recipient slot has been permanently locked by the
    ///         token admin. One-way; mirrors `poolExtensionLocked`.
    mapping(PoolId => bool) public sniperFeeRecipientLocked;
    /// @notice One-shot per-swap value: the extra ppm signaled by the MEV
    ///         module for the in-progress swap. Cleared after consumption in
    ///         `_beforeSwap` so it never carries between swaps.
    mapping(PoolId => uint24) public currentSniperExtraFeePpm;
    /// @notice Accrued sniper-extra in token0, awaiting flush to recipient.
    mapping(PoolId => uint256) public sniperExtraAccruedToken0;
    /// @notice Accrued sniper-extra in token1, awaiting flush to recipient.
    mapping(PoolId => uint256) public sniperExtraAccruedToken1;

    /// @dev Restricts a function to the factory.
    modifier onlyFactory() {
        if (msg.sender != factory) {
            revert OnlyFactory();
        }
        _;
    }

    /// @param _poolManager Uniswap v4 pool manager.
    /// @param _factory The ArtCoins factory.
    /// @param _poolExtensionAllowlist Pool-extension allowlist contract.
    /// @param _weth WETH address.
    /// @param _feeEscrow Fee escrow (used to route native-ETH sniper-extra fees).
    constructor(
        address _poolManager,
        address _factory,
        address _poolExtensionAllowlist,
        address _weth,
        address _feeEscrow
    ) BaseHook(IPoolManager(_poolManager)) {
        factory = _factory;
        poolExtensionAllowlist = IArtCoinsPoolExtensionAllowlist(_poolExtensionAllowlist);
        weth = _weth;
        feeEscrow = IArtCoinsFeeEscrow(_feeEscrow);
    }

    /// @notice Accept native ETH. Required because `_sniperExtraFeeClaim` takes
    ///         native-ETH sniper-extra into this contract (via
    ///         `poolManager.take(currency0, address(this), amt)`) before
    ///         forwarding to the fee escrow. The hook never holds ETH across
    ///         calls — any ETH received is immediately forwarded.
    receive() external payable {}

    // function to for inheriting hooks to set fees in _beforeSwap hook
    function _setFee(PoolKey calldata poolKey, IPoolManager.SwapParams calldata swapParams)
        internal
        virtual
    {
        return;
    }

    /// @dev Returns the art-coin token bound to a pool, derived from the
    ///      hook's `artCoinIsToken0` mapping (set during pool init).
    function _artCoinFor(PoolKey calldata pk) internal view returns (address) {
        return
            artCoinIsToken0[pk.toId()]
                ? Currency.unwrap(pk.currency0)
                : Currency.unwrap(pk.currency1);
    }

    /// @dev Restricts a function to the pool's token admin (the address
    ///      stored as `_admin` on the art-coin token, settable via the
    ///      token's `updateAdmin`). Renouncing admin to address(0)
    ///      permanently disables this gate.
    modifier onlyTokenAdmin(PoolKey calldata pk) {
        if (msg.sender != ArtCoinsToken(_artCoinFor(pk)).admin()) {
            revert NotTokenAdmin();
        }
        _;
    }

    /// @notice Replaces the pool's extension contract with another allowlisted
    ///         one, re-running the extension's init callbacks so it can wire
    ///         up its own state. Token admin only; allowlist-gated; reverts
    ///         when the slot is locked via `lockPoolExtension`.
    /// @dev    Pass `address(0)` to disable the slot entirely (no afterSwap
    ///         dispatch for future trades). Passing a non-zero address that
    ///         isn't on the allowlist reverts.
    /// @param  pk                   The pool key.
    /// @param  newExtension         The replacement extension (or zero to clear).
    /// @param  poolExtensionInitData Init payload forwarded to
    ///         `initializePreLockerSetup` on the new extension. Empty is fine
    ///         for stateless extensions; project-specific extensions can use
    ///         this to migrate state from a prior extension if desired.
    function setPoolExtension(
        PoolKey calldata pk,
        address newExtension,
        bytes calldata poolExtensionInitData
    ) external onlyTokenAdmin(pk) {
        PoolId id = pk.toId();
        if (poolExtensionLocked[id]) revert PoolExtensionLockedErr();
        if (newExtension != address(0) && !poolExtensionAllowlist.enabledExtensions(newExtension)) {
            revert PoolExtensionNotEnabled();
        }

        address oldExtension = poolExtension[id];
        poolExtension[id] = newExtension;

        if (newExtension != address(0)) {
            // Run both init callbacks on the new extension so it can wire up
            // any state it needs (e.g. token ↔ pool mapping). Locker is
            // already set from the original `initializePool` flow, so
            // `initializePostLockerSetup` has the address it needs.
            IArtCoinsPoolExtension(newExtension)
                .initializePreLockerSetup(pk, artCoinIsToken0[id], poolExtensionInitData);
            IArtCoinsPoolExtension(newExtension)
                .initializePostLockerSetup(pk, locker[id], artCoinIsToken0[id]);
            poolExtensionSetup[id] = true;
        } else {
            // Cleared — afterSwap dispatch will skip on the next swap.
            poolExtensionSetup[id] = false;
        }

        emit PoolExtensionSwapped(id, oldExtension, newExtension);
    }

    /// @notice Sets the per-pool recipient that will receive sniper-extra
    ///         fees collected via the bound MEV module's anti-sniper schedule.
    ///         Token admin only. Reverts if the slot is locked.
    /// @dev    Set to a deflationary destination (e.g. BurnRouter for LAYER)
    ///         to make the launch-protection extra route 100% to buy-and-burn
    ///         instead of through the normal locker reward split.
    /// @param  poolKey The pool key.
    /// @param  recipient The recipient address (zero clears the slot and
    ///         disables the path; non-zero enables it).
    function setSniperFeeRecipient(PoolKey calldata poolKey, address recipient)
        external
        onlyTokenAdmin(poolKey)
    {
        PoolId id = poolKey.toId();
        if (sniperFeeRecipientLocked[id]) revert SniperFeeRecipientLockedErr();
        _setSniperFeeRecipient(id, recipient);
    }

    /// @notice Factory-only deploy-time setup for sniper-extra routing.
    /// @dev    Lets deployments atomically bind and lock the recipient before
    ///         liquidity, extensions, and MEV activation make the pool live.
    /// @param  poolKey The pool key.
    /// @param  recipient The recipient address (zero disables the path unless locked).
    /// @param  lockRecipient Whether to permanently lock the recipient after setting it.
    function factorySetSniperFeeRecipient(
        PoolKey calldata poolKey,
        address recipient,
        bool lockRecipient
    ) external onlyFactory {
        PoolId id = poolKey.toId();
        if (sniperFeeRecipientLocked[id]) revert SniperFeeRecipientLockedErr();
        if (lockRecipient && recipient == address(0)) revert InvalidSniperFeeConfig();
        _setSniperFeeRecipient(id, recipient);
        if (lockRecipient) {
            sniperFeeRecipientLocked[id] = true;
            emit SniperFeeRecipientLockedEvt(id);
        }
    }

    /// @notice Permanently locks the pool's sniper-fee recipient slot so it
    ///         can never be changed again. Token admin only. One-way.
    /// @dev    Use this to credibly commit to BurnRouter (or any other
    ///         destination) for the lifetime of the pool. After this returns,
    ///         all future `setSniperFeeRecipient` calls revert.
    /// @param  poolKey The pool key.
    function lockSniperFeeRecipient(PoolKey calldata poolKey) external onlyTokenAdmin(poolKey) {
        PoolId id = poolKey.toId();
        if (sniperFeeRecipientLocked[id]) revert SniperFeeRecipientLockedErr();
        sniperFeeRecipientLocked[id] = true;
        emit SniperFeeRecipientLockedEvt(id);
    }

    function _setSniperFeeRecipient(PoolId id, address recipient) internal {
        address old = sniperFeeRecipient[id];
        sniperFeeRecipient[id] = recipient;
        emit SniperFeeRecipientSet(id, old, recipient);
    }

    /// @notice Permanently locks the pool's extension slot so it can never be
    ///         swapped again. Token admin only. One-way operation.
    /// @dev    Use this to credibly commit to a specific extension (e.g. a
    ///         data-counter contract whose state you don't want to be able
    ///         to retroactively orphan). After this returns, all future
    ///         `setPoolExtension` calls revert.
    /// @param  pk The pool key.
    function lockPoolExtension(PoolKey calldata pk) external onlyTokenAdmin(pk) {
        PoolId id = pk.toId();
        if (poolExtensionLocked[id]) revert PoolExtensionLockedErr();
        poolExtensionLocked[id] = true;
        emit PoolExtensionLockedEvt(id);
    }

    // function to for inheriting hooks to set process data in during initialization flow
    function _initializeFeeData(PoolKey memory poolKey, bytes memory feeData) internal virtual {
        return;
    }

    function _initializePoolExtensionData(
        PoolKey memory poolKey,
        address _poolExtension,
        bytes memory poolExtensionData
    ) internal virtual {
        if (_poolExtension != address(0)) {
            // check that the pool extension is enabled
            if (!poolExtensionAllowlist.enabledExtensions(_poolExtension)) {
                revert PoolExtensionNotEnabled();
            }

            IArtCoinsPoolExtension(_poolExtension)
                .initializePreLockerSetup(
                    poolKey, artCoinIsToken0[poolKey.toId()], poolExtensionData
                );
            poolExtension[poolKey.toId()] = _poolExtension;
        }
        return;
    }

    /// @inheritdoc IArtCoinsHook
    function initializePool(
        address artCoin,
        address pairedToken,
        int24 tickIfToken0IsArtCoins,
        int24 tickSpacing,
        address _locker,
        address _mevModule,
        bytes calldata poolData
    ) public onlyFactory returns (PoolKey memory) {
        // initialize the pool
        PoolKey memory poolKey =
            _initializePool(artCoin, pairedToken, tickIfToken0IsArtCoins, tickSpacing, poolData);

        // set the locker config
        locker[poolKey.toId()] = _locker;

        // set the mev module
        mevModule[poolKey.toId()] = _mevModule;

        emit PoolCreatedFactory({
            pairedToken: pairedToken,
            artCoin: artCoin,
            poolId: poolKey.toId(),
            tickIfToken0IsArtCoins: tickIfToken0IsArtCoins,
            tickSpacing: tickSpacing,
            locker: _locker,
            mevModule: _mevModule
        });

        emit PoolExtensionRegistered(poolKey.toId(), poolExtension[poolKey.toId()]);

        return poolKey;
    }

    /// @inheritdoc IArtCoinsHook
    /// @dev Permissionless path that allows tokens NOT created by the factory to use this hook.
    ///      Pools created via this path lack LP locker auto-claim, pool extensions, and MEV module
    ///      functionality.
    function initializePoolOpen(
        address artCoin,
        address pairedToken,
        int24 tickIfToken0IsArtCoins,
        int24 tickSpacing,
        bytes calldata poolData
    ) public returns (PoolKey memory) {
        // if able, we prefer that weth is not the art coin token as our hook fee will only
        // collect fees on the paired token
        if (artCoin == weth) {
            revert WethCannotBeArtCoins();
        }

        // Require an already-deployed token. An `artCoin` with no code may be a
        // predicted, not-yet-deployed CREATE2 address; pre-creating its pool
        // here would make the factory's later initialization of the same pool
        // key revert `PoolAlreadyInitialized`, blocking that token's launch.
        // A token that already has code cannot be a factory deploy in flight.
        if (artCoin.code.length == 0) {
            revert ArtCoinNotDeployed();
        }

        PoolKey memory poolKey =
            _initializePool(artCoin, pairedToken, tickIfToken0IsArtCoins, tickSpacing, poolData);

        // check that the pool's extension was not set
        //
        // non-factory pools have no way of triggering the initializePostLockerSetup step
        // and in general will lack fees to do things with
        if (poolExtension[poolKey.toId()] != address(0)) {
            revert OnlyFactoryPoolsCanHaveExtensions();
        }

        emit PoolCreatedOpen(
            pairedToken, artCoin, poolKey.toId(), tickIfToken0IsArtCoins, tickSpacing
        );

        return poolKey;
    }

    // common actions for initializing a pool
    function _initializePool(
        address artCoin,
        address pairedToken,
        int24 tickIfToken0IsArtCoins,
        int24 tickSpacing,
        bytes calldata poolData
    ) internal virtual returns (PoolKey memory) {
        // Native-ETH pairing is allowed. Only the artcoin
        // side must be a real ERC20 (V4's currency layout uses address(0) as
        // the native-ETH sentinel, which is correct for currency0 of an
        // ETH-paired pool but would be nonsensical for an artcoin).
        if (artCoin == address(0)) revert ETHPoolNotAllowed();

        // determine if art coin token is token0
        bool token0IsArtCoins = artCoin < pairedToken;

        // create the pool key
        PoolKey memory _poolKey = PoolKey({
            currency0: Currency.wrap(token0IsArtCoins ? artCoin : pairedToken),
            currency1: Currency.wrap(token0IsArtCoins ? pairedToken : artCoin),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(this))
        });

        // Set the storage helpers
        artCoinIsToken0[_poolKey.toId()] = token0IsArtCoins;

        // initialize the pool
        int24 startingTick = token0IsArtCoins ? tickIfToken0IsArtCoins : -tickIfToken0IsArtCoins;
        uint160 initialPrice = startingTick.getSqrtPriceAtTick();
        poolManager.initialize(_poolKey, initialPrice);

        // set the pool creation timestamp
        poolCreationTimestamp[_poolKey.toId()] = block.timestamp;

        // decode the pool data into user extension data and pool data
        PoolInitializationData memory poolInitializationData =
            abi.decode(poolData, (PoolInitializationData));

        // initialize fee data
        _initializeFeeData(_poolKey, poolInitializationData.feeData);

        // initialize pool extension data
        _initializePoolExtensionData(
            _poolKey, poolInitializationData.extension, poolInitializationData.extensionData
        );

        return _poolKey;
    }

    /// @notice Enables the MEV module after pool deployment completes.
    /// @dev Split from `initializePool` so extensions can take pool actions in between.
    /// @param poolKey The pool key.
    /// @param mevModuleData ABI-encoded MEV module init data.
    function initializeMevModule(PoolKey calldata poolKey, bytes calldata mevModuleData)
        external
        onlyFactory
    {
        // initialize the mev module
        IArtCoinsMevModuleBase(mevModule[poolKey.toId()]).initialize(poolKey, mevModuleData);

        // give pool extension, if it exists, chance to check other configured settings
        if (poolExtension[poolKey.toId()] != address(0)) {
            IArtCoinsPoolExtension(poolExtension[poolKey.toId()])
                .initializePostLockerSetup(
                    poolKey, locker[poolKey.toId()], artCoinIsToken0[poolKey.toId()]
                );
            // set the pool extension setup to true
            poolExtensionSetup[poolKey.toId()] = true;
        }

        // enable the mev module
        mevModuleEnabled[poolKey.toId()] = true;
    }

    /// @notice Checks whether a pool's MEV module is operational and disables it on expiry.
    /// @param poolId The pool id.
    /// @return True if currently operational.
    function mevModuleOperational(PoolId poolId) public returns (bool) {
        if (!mevModuleEnabled[poolId]) {
            return false;
        } else if (block.timestamp >= poolCreationTimestamp[poolId] + MAX_MEV_MODULE_DELAY) {
            // mev module has expired
            mevModuleEnabled[poolId] = false;
            emit MevModuleDisabled(poolId);
            return false;
        }

        // mev module is operational
        return true;
    }

    /// @notice Lets the bound MEV module raise the dynamic LP fee for the next swap.
    /// @dev Silently no-ops if not operational, the fee exceeds `MAX_MEV_LP_FEE`, or the
    ///      requested fee isn't higher than the current LP fee.
    /// @param poolKey The pool key.
    /// @param fee The desired LP fee.
    function mevModuleSetFee(PoolKey calldata poolKey, uint24 fee) external {
        // only the assigned mev module for a poolkey can update the fee
        if (mevModule[poolKey.toId()] != msg.sender) {
            revert Unauthorized();
        }

        // skip if the mev module is not operational
        if (!mevModuleOperational(poolKey.toId())) {
            return;
        }

        // skip if the mev module is trying to set the fee higher than the max MEV fee
        if (fee > MAX_MEV_LP_FEE) {
            return;
        }

        // check to see if the fee is higher than the currently set LP fee,
        // we only want to update if it is higher than the pool's normal fee behavior
        (,,, uint24 currentLpFee) = StateLibrary.getSlot0(poolManager, poolKey.toId());
        if (fee <= currentLpFee) {
            return;
        }

        // update the fee for the swap
        IPoolManager(poolManager).updateDynamicLPFee(poolKey, fee);

        emit MevModuleSetFee(poolKey.toId(), fee);
    }

    /// @notice Lets the bound MEV module signal an "extra" fee on top of the
    ///         pool's base LP fee for the in-progress swap. The hook collects
    ///         the extra from the swap's input currency in `_beforeSwap` and
    ///         lazily flushes it to `sniperFeeRecipient[pid]` on the next
    ///         swap. The pool's LP fee is NOT changed by this call — the
    ///         locker reward split still receives only the base pool fee.
    /// @dev    Silent no-op if the MEV module is not operational, the caller
    ///         is not the bound MEV module, or `extraPpm > MAX_MEV_LP_FEE`.
    ///         Stored value is consumed exactly once in `_beforeSwap`.
    /// @param  poolKey The pool key.
    /// @param  extraPpm Extra fee in ppm (1e6 = 100%).
    function mevModuleSetSniperFee(PoolKey calldata poolKey, uint24 extraPpm) external {
        PoolId id = poolKey.toId();
        if (mevModule[id] != msg.sender) {
            revert Unauthorized();
        }
        if (!mevModuleOperational(id)) {
            return;
        }
        if (extraPpm > MAX_MEV_LP_FEE) {
            return;
        }
        currentSniperExtraFeePpm[id] = extraPpm;
        emit MevModuleSetSniperFee(id, extraPpm);
    }

    function _runMevModule(
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata swapParams,
        bytes calldata swapData
    ) internal {
        if (mevModuleOperational(poolKey.toId())) {
            // decode the swap data — tolerant of malformed input so a
            // wrong-shaped `swapData` cannot revert the swap in the MEV window
            PoolSwapData memory poolSwapData = _decodeSwapDataTolerant(swapData);

            // if the mev module is enabled  call it
            bool disableMevModule = IArtCoinsMevModule(mevModule[poolKey.toId()])
                .beforeSwap(
                    poolKey,
                    swapParams,
                    artCoinIsToken0[poolKey.toId()],
                    poolSwapData.mevModuleSwapData
                );

            // disable the mevModule if the module requests it
            if (disableMevModule) {
                mevModuleEnabled[poolKey.toId()] = false;
                emit MevModuleDisabled(poolKey.toId());
            }
        }
    }

    function _runPoolExtension(
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata swapParams,
        address sender,
        BalanceDelta delta,
        bytes calldata swapData
    ) internal {
        // only run the pool extension if it exists, is setup, and the sender is not the locker.
        // we don't want to run it when the locker is swapping because it will run the
        // extension code before the user's swap is complete
        if (
            poolExtension[poolKey.toId()] != address(0) && poolExtensionSetup[poolKey.toId()]
                && sender != locker[poolKey.toId()]
        ) {
            // decode the swap data — tolerant of malformed input so a
            // wrong-shaped `swapData` cannot revert the swap
            PoolSwapData memory poolSwapData = _decodeSwapDataTolerant(swapData);

            try this._runPoolExtensionHelper(
                poolKey, swapParams, delta, poolSwapData.poolExtensionSwapData
            ) {
                emit PoolExtensionSuccess(poolKey.toId());
            } catch {
                emit PoolExtensionFailed(poolKey.toId(), swapParams);
            }
        }
    }

    function _runPoolExtensionHelper(
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata swapData
    ) external {
        if (msg.sender != address(this)) {
            revert OnlyThis();
        }

        IArtCoinsPoolExtension(poolExtension[poolKey.toId()])
            .afterSwap(poolKey, swapParams, delta, artCoinIsToken0[poolKey.toId()], swapData);
    }

    /// @dev Decode `swapData` into a `PoolSwapData`, tolerant of malformed
    ///      input: an empty or non-decodable payload yields an empty struct
    ///      instead of reverting, so a swap carrying wrong-shaped `swapData`
    ///      is treated as having no MEV/extension data rather than failing.
    function _decodeSwapDataTolerant(bytes calldata swapData)
        internal
        view
        returns (PoolSwapData memory)
    {
        if (swapData.length > 0) {
            try this._abiDecodePoolSwapData(swapData) returns (PoolSwapData memory psd) {
                return psd;
            } catch {}
        }
        return PoolSwapData({mevModuleSwapData: new bytes(0), poolExtensionSwapData: new bytes(0)});
    }

    /// @dev External so a malformed-input `abi.decode` revert is catchable via
    ///      `try`/`catch` in `_decodeSwapDataTolerant` (a decode failure is
    ///      only catchable across an external-call boundary). `pure` and
    ///      unguarded — a bare decode helper; an external call to it is inert.
    function _abiDecodePoolSwapData(bytes calldata data)
        external
        pure
        returns (PoolSwapData memory)
    {
        return abi.decode(data, (PoolSwapData));
    }

    /// @dev Lazy-flushes prior swap's accrued sniper-extra to the per-pool
    ///      `sniperFeeRecipient`. Uses an explicit per-currency accumulator
    ///      (`sniperExtraAccruedToken0/1`) rather than the hook's full
    ///      claim-token balance, so it flushes exactly what the sniper path
    ///      accrued and nothing else. Called near the top of `_beforeSwap`.
    ///
    ///      Native-ETH flushes route through the fee escrow
    ///      (`feeEscrow.storeFeesNative{value:}`) instead of pushing ETH
    ///      directly to the recipient. A push-payment path would brick a
    ///      native-ETH pool if the recipient is a contract that rejects ETH
    ///      (e.g., a locked, non-payable recipient). Routing through the escrow
    ///      makes the flush always succeed: the escrow accepts any recipient
    ///      and holds the balance for them to claim (or `claimTo`) at their
    ///      convenience.
    function _sniperExtraFeeClaim(PoolKey calldata poolKey) internal {
        PoolId id = poolKey.toId();
        address recipient = sniperFeeRecipient[id];
        if (recipient == address(0)) return;

        uint256 amt0 = sniperExtraAccruedToken0[id];
        uint256 amt1 = sniperExtraAccruedToken1[id];

        if (amt0 > 0) {
            sniperExtraAccruedToken0[id] = 0;
            poolManager.burn(address(this), poolKey.currency0.toId(), amt0);
            _routeSniperExtra(poolKey.currency0, recipient, amt0);
            emit SniperExtraFeeFlushed(id, Currency.unwrap(poolKey.currency0), amt0, recipient);
        }
        if (amt1 > 0) {
            sniperExtraAccruedToken1[id] = 0;
            poolManager.burn(address(this), poolKey.currency1.toId(), amt1);
            _routeSniperExtra(poolKey.currency1, recipient, amt1);
            emit SniperExtraFeeFlushed(id, Currency.unwrap(poolKey.currency1), amt1, recipient);
        }
    }

    /// @dev Routes a sniper-extra flush. Native ETH goes via the fee escrow
    ///      (push-safe — escrow accepts any recipient). ERC20 goes via the
    ///      direct-take path. Native-ETH currency is
    ///      identified by `Currency.unwrap(currency) == address(0)`.
    function _routeSniperExtra(Currency currency, address recipient, uint256 amount) internal {
        address unwrapped = Currency.unwrap(currency);
        if (unwrapped == address(0)) {
            // Native ETH: take to self, then forward to escrow.
            // Reverts cleanly if the escrow's depositor allowlist doesn't
            // include this hook — that's a misconfiguration the deploy
            // script must prevent (`escrow.addDepositor(hook)`).
            poolManager.take(currency, address(this), amount);
            feeEscrow.storeFeesNative{value: amount}(recipient);
        } else {
            // ERC20: direct push to recipient.
            poolManager.take(currency, recipient, amount);
        }
    }

    function _beforeSwap(
        address,
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata swapParams,
        bytes calldata swapData
    ) internal virtual override returns (bytes4, BeforeSwapDelta delta, uint24) {
        // set the fee for this swap
        _setFee(poolKey, swapParams);

        // flush any sniper-extra accrued in the previous swap to the per-pool
        // recipient (lazy flush — the input currency from this swap hasn't
        // settled yet, so we can only forward fees that already settled in
        // prior swaps).
        _sniperExtraFeeClaim(poolKey);

        // No LP-locker auto-claim on swap. Poking the locker (position poke
        // + per-recipient escrow deposit, ~600-800k gas) on every swap is
        // avoided; the claim is pull-based. V4 positions accrue fees natively;
        // any keeper can call `lpLocker.collectRewards(token)` when it
        // is economical, and downstream payouts (BurnRouter / FeeAutoSwapper)
        // already pay keeper rewards that cover the gas.

        // run the mev module, can update the fee for the swap
        _runMevModule(poolKey, swapParams, swapData);

        bool isExactInput = swapParams.amountSpecified < 0;

        // Sniper-extra skim for exactInput swaps. The MEV module signalled the
        // extra ppm via `mevModuleSetSniperFee` during `_runMevModule`.
        // ExactOutput swaps fall through to the matching `_afterSwap` branch
        // where the realized input amount is known. The slot is cleared exactly
        // once per swap, in `_afterSwap`, so the value is visible to both this
        // block and the afterSwap branch.
        {
            PoolId pid = poolKey.toId();
            uint24 extraPpm = currentSniperExtraFeePpm[pid];
            if (extraPpm > 0) {
                if (sniperFeeRecipient[pid] != address(0) && isExactInput) {
                    // |amountSpecified| as uint256, then ppm fraction of it.
                    // amountSpecified is negative under isExactInput, so the
                    // negation is positive and the int256→uint256 cast is a
                    // direct value preservation.
                    uint256 amountIn = uint256(-swapParams.amountSpecified);
                    uint256 extra256 = amountIn * uint256(extraPpm) / 1_000_000;
                    if (extra256 > 0 && extra256 <= uint256(uint128(type(int128).max))) {
                        bool inputIsToken0 = swapParams.zeroForOne;
                        uint256 inputCcyId =
                            inputIsToken0 ? poolKey.currency0.toId() : poolKey.currency1.toId();

                        // Mint claim tokens in the input currency. These
                        // settle when the swapper pays for the swap; we flush
                        // them to the recipient on the next swap via
                        // `_sniperExtraFeeClaim`.
                        poolManager.mint(address(this), inputCcyId, extra256);

                        if (inputIsToken0) {
                            sniperExtraAccruedToken0[pid] += extra256;
                        } else {
                            sniperExtraAccruedToken1[pid] += extra256;
                        }

                        // Add to BeforeSwapDelta on the specified (input)
                        // side — this charges the trader by `extra` more on
                        // the input side and reduces the amount that reaches
                        // the LP swap by the same amount. We recompose
                        // manually because `BeforeSwapDeltaLibrary` does not
                        // expose an `add`.
                        int128 newSpecified = delta.getSpecifiedDelta() + int128(uint128(extra256));
                        int128 unspecified = delta.getUnspecifiedDelta();
                        delta = toBeforeSwapDelta(newSpecified, unspecified);

                        emit SniperExtraFeeAccrued(
                            pid,
                            inputIsToken0
                                ? Currency.unwrap(poolKey.currency0)
                                : Currency.unwrap(poolKey.currency1),
                            extra256
                        );
                    }
                }
            }
        }

        return (BaseHook.beforeSwap.selector, delta, 0);
    }

    function _afterSwap(
        address sender,
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata swapData
    ) internal virtual override returns (bytes4, int128 unspecifiedDelta) {
        bool swappingForArtCoins = swapParams.zeroForOne != artCoinIsToken0[poolKey.toId()];
        bool isExactInput = swapParams.amountSpecified < 0;

        // Sniper-extra skim for exactOutput swaps: read the realized input
        // amount from the post-swap delta, mint claim tokens in the input
        // currency to the hook, accrue for lazy-flush in the next swap's
        // `_sniperExtraFeeClaim`, and add to `unspecifiedDelta` so the
        // trader's settlement on the input side is increased by the skim.
        //
        // Required because at `_beforeSwap` time we don't know the input
        // amount for exactOutput swaps. Without this branch, an exactOutput
        // route is a sniper bypass during the launch window. Together with
        // the `_beforeSwap` exactInput branch, every swap direction is
        // covered.
        //
        // The slot is read once and ALWAYS cleared below (regardless of
        // which branch fired) so a stale value can never leak into a
        // subsequent swap if the MEV module has expired between calls.
        {
            PoolId pid = poolKey.toId();
            uint24 sniperPpm = currentSniperExtraFeePpm[pid];
            if (sniperPpm > 0) {
                currentSniperExtraFeePpm[pid] = 0;
                if (!isExactInput && sniperFeeRecipient[pid] != address(0)) {
                    bool inputIsToken0 = swapParams.zeroForOne;
                    int128 inputDelta = inputIsToken0 ? delta.amount0() : delta.amount1();
                    // inputDelta is negative (user paid into the pool).
                    // sniperSkim = |inputDelta| * sniperPpm / 1e6, expressed
                    // as a positive int128 by negating the multiplier.
                    int128 sniperSkim = inputDelta * -int128(int24(sniperPpm)) / FEE_DENOMINATOR;

                    if (sniperSkim > 0) {
                        uint256 sniperSkimU = uint256(int256(sniperSkim));
                        uint256 inputCcyId =
                            inputIsToken0 ? poolKey.currency0.toId() : poolKey.currency1.toId();

                        // Add to unspecifiedDelta so the user pays the
                        // skim on the input side at settlement time.
                        // `unspecifiedDelta` starts at 0 (this hook has no
                        // protocol-fee branch), so this is its only contributor.
                        unspecifiedDelta += sniperSkim;

                        // Mint claim tokens in the input currency to the
                        // hook. Lazy-flushed to the recipient on the next
                        // swap via `_sniperExtraFeeClaim`.
                        poolManager.mint(address(this), inputCcyId, sniperSkimU);
                        if (inputIsToken0) {
                            sniperExtraAccruedToken0[pid] += sniperSkimU;
                        } else {
                            sniperExtraAccruedToken1[pid] += sniperSkimU;
                        }

                        // Adjust `delta` so `_runPoolExtension` sees post-skim
                        // amounts. The negative side is whichever currency the
                        // user paid in.
                        if (delta.amount0() < 0) {
                            delta = sub(delta, toBalanceDelta(sniperSkim, 0));
                        } else {
                            delta = sub(delta, toBalanceDelta(0, sniperSkim));
                        }

                        emit SniperExtraFeeAccrued(
                            pid,
                            inputIsToken0
                                ? Currency.unwrap(poolKey.currency0)
                                : Currency.unwrap(poolKey.currency1),
                            sniperSkimU
                        );
                    }
                }
            }
        }

        // When the sniper-extra skim reduced the specified (paired) input in
        // `_beforeSwap` — the `isExactInput && swappingForArtCoins` case — the
        // swap delta's paired side is net of the skim. Reset it to the user's
        // `amountSpecified` so a bound pool extension sees the trader's true
        // input. No-op for the `!isExactInput && !swappingForArtCoins` case
        // (the paired side already equals `amountSpecified`).
        if (isExactInput && swappingForArtCoins || !isExactInput && !swappingForArtCoins) {
            if (artCoinIsToken0[poolKey.toId()]) {
                delta = toBalanceDelta(delta.amount0(), int128(swapParams.amountSpecified));
            } else {
                delta = toBalanceDelta(int128(swapParams.amountSpecified), delta.amount1());
            }
        }

        // run the pool extension
        _runPoolExtension(poolKey, swapParams, sender, delta, swapData);

        return (BaseHook.afterSwap.selector, unspecifiedDelta);
    }

    // prevent initializations that don't start via our initializePool functions
    function _beforeInitialize(address, PoolKey calldata, uint160)
        internal
        virtual
        override
        returns (bytes4)
    {
        revert UnsupportedInitializePath();
    }

    // prevent liquidity adds during mev module operation
    function _beforeAddLiquidity(
        address,
        PoolKey calldata poolKey,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) internal virtual override returns (bytes4) {
        if (mevModuleOperational(poolKey.toId())) {
            revert MevModuleEnabled();
        }

        return BaseHook.beforeAddLiquidity.selector;
    }

    /// @notice ERC-165 introspection.
    /// @param interfaceId The interface id.
    /// @return True if supported.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IArtCoinsHook).interfaceId;
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
