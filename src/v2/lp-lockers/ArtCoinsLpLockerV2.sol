// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Constants} from "../../Constants.sol";
import {IArtCoinsFactoryV2} from "../interfaces/IArtCoinsFactoryV2.sol";
import {IArtCoinsHookV2} from "../interfaces/IArtCoinsHookV2.sol";
import {IArtCoinsLpLockerV2} from "../interfaces/IArtCoinsLpLockerV2.sol";
import {IArtCoinsTokenV2} from "../interfaces/IArtCoinsTokenV2.sol";
import {IConstantsBound} from "../interfaces/IConstantsBound.sol";
import {FeeDelivery} from "../libraries/FeeDelivery.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @dev Minimal read of the factory for the reward recipient reject set.
interface IFactoryTokenDeployer {
    function tokenDeployer() external view returns (address);
}

/// @title  ArtCoinsLpLockerV2
/// @notice Holds each v2 coin's launch liquidity forever (no decrease path) and
///         splits collected lp fees. The split bps are set once at launch; the
///         coin admin may change a project reward recipient, the protocol slot
///         stays frozen. Shares are pushed (eth with a gas cap, coin with a
///         plain transfer); a failed push is credited to the recipient in the
///         fee escrow.
/// @dev    Native eth paired pools only (D17): currency0 is eth, currency1 is
///         the coin. The locker holds nothing between calls; any balance is
///         stray and rescuable.
///         LF-01: there is no "without unlock" collect. `collectRewards` opens
///         its own PositionManager unlock, refuses to run while the
///         PoolManager is already unlocked, and sizes amounts from its own
///         balance deltas.
contract ArtCoinsLpLockerV2 is IArtCoinsLpLockerV2, Ownable2Step, ReentrancyGuardTransient {
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // ── additive errors (not in the frozen interface) ─────────────────────

    /// @notice `collectRewards` was called while the PoolManager is unlocked
    ///         by someone else (LF-01 attack shape).
    error PoolManagerUnlocked();
    /// @notice Pool key is not a native eth pair of `token` with the configured
    ///         hook and tick spacing.
    error UnsupportedPoolKey();
    /// @notice Rescue target is the PositionManager (lp nfts are never movable).
    error RescueForbidden();
    /// @notice Native eth may only arrive from the PoolManager.
    error UnexpectedEth();
    /// @notice The caller is not the coin's current admin.
    error NotCoinAdmin();
    /// @notice The coin's recipients are frozen (the coin called `lockRecipients`
    ///         or renounced its admin).
    error RecipientsLocked();
    /// @notice `setRewardRecipient` index is past the reward slots.
    error RewardIndexOutOfRange();
    /// @notice The protocol reward slot is frozen; the coin admin changes the
    ///         project slots.
    error ProtocolSlotFrozen();
    /// @notice A reward recipient the factory launch checks reject for this role:
    ///         the coin, this locker, its fee escrow, the pool hook's fee escrow,
    ///         the pool's hook, the PoolManager, the PositionManager, the pool's
    ///         mev module, the factory or its token deployer.
    error RecipientCannotReceive(address recipient);
    /// @notice A reject-set lookup (token deployer, pool mev module or pool hook
    ///         fee escrow) reverted, so the recipient could not be verified. The
    ///         setter refuses the change rather than skip a check.
    error RecipientCheckFailed();

    /// @notice Gas forwarded on each native reward push. A recipient that
    ///         needs more is credited in the escrow instead.
    uint256 public constant PUSH_GAS = Constants.PUSH_GAS_MAX;

    IPositionManager public immutable positionManager;
    IPoolManager public immutable poolManager;
    IPermit2 public immutable permit2;

    /// @inheritdoc IArtCoinsLpLockerV2
    uint256 public keeperRewardBps;
    /// @inheritdoc IArtCoinsLpLockerV2
    uint256 public keeperRewardCap = 0.01 ether;
    /// @inheritdoc IArtCoinsLpLockerV2
    address public feeEscrow;
    /// @inheritdoc IArtCoinsLpLockerV2
    mapping(address launcher => bool) public isLauncher;

    mapping(address token => TokenRewardInfoV2) internal _tokenRewards;
    /// @dev Reward slot index of the frozen protocol slot, plus one; 0 means the
    ///      launch appended no protocol slot. Written once at placement from the
    ///      launch data. `setRewardRecipient` refuses this slot.
    mapping(address token => uint256) internal _protocolSlotPlusOne;

    constructor(address owner_, address positionManager_, address permit2_, address feeEscrow_)
        Ownable(owner_)
    {
        if (positionManager_ == address(0) || permit2_ == address(0)) revert ZeroAddress();
        positionManager = IPositionManager(positionManager_);
        poolManager = positionManager.poolManager();
        permit2 = IPermit2(permit2_);
        _setFeeEscrow(feeEscrow_);
    }

    /// @dev Eth arrives only from `PoolManager.take` during collection.
    receive() external payable {
        if (msg.sender != address(poolManager)) revert UnexpectedEth();
    }

    /// @inheritdoc IConstantsBound
    function constantsHash() external pure returns (bytes32) {
        return Constants.hash();
    }

    // ── launcher ──────────────────────────────────────────────────────────

    /// @inheritdoc IArtCoinsLpLockerV2
    /// @dev Pulls `poolSupply` of `token` from the launcher (prior approval),
    ///         mints coin only positions below the starting price and freezes
    ///         the split. Rounding dust of the coin is sent to `Constants.DEAD`.
    ///         `protocolSlotIndex` is the reward slot the launcher appended for
    ///         the protocol (frozen against `setRewardRecipient`);
    ///         `type(uint256).max` means no protocol slot.
    function placeLiquidity(
        IArtCoinsFactoryV2.LockerConfigV2 calldata lockerConfig,
        IArtCoinsFactoryV2.PoolConfigV2 calldata poolConfig,
        PoolKey calldata poolKey,
        uint256 poolSupply,
        address token,
        uint256 protocolSlotIndex
    ) external nonReentrant returns (uint256 positionId) {
        if (!isLauncher[msg.sender]) revert NotLauncher();
        if (token == address(0)) revert ZeroAddress();
        if (_tokenRewards[token].numPositions != 0) revert TokenAlreadyHasRewards();
        if (
            protocolSlotIndex != type(uint256).max
                && protocolSlotIndex >= lockerConfig.rewardRecipients.length
        ) revert RewardIndexOutOfRange();

        address hook = address(poolKey.hooks);
        if (
            !poolKey.currency0.isAddressZero() || Currency.unwrap(poolKey.currency1) != token
                || hook != poolConfig.hook || poolKey.tickSpacing != poolConfig.tickSpacing
        ) revert UnsupportedPoolKey();
        _checkConstants(hook);

        _validateRewards(lockerConfig.rewardRecipients, lockerConfig.rewardBps);
        uint256 numPositions =
            _validatePositions(lockerConfig, poolConfig.tickIfToken0IsArtCoin, poolKey.tickSpacing);

        uint256 balBefore = SafeTransferLib.balanceOf(token, address(this));
        SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), poolSupply);

        positionId =
            _mint(lockerConfig, poolConfig.tickIfToken0IsArtCoin, poolKey, poolSupply, token);

        // send any coin left after placement (rounding dust) to the burn sink
        uint256 balAfter = SafeTransferLib.balanceOf(token, address(this));
        if (balAfter > balBefore) {
            SafeTransferLib.safeTransfer(token, Constants.DEAD, balAfter - balBefore);
        }

        TokenRewardInfoV2 storage info = _tokenRewards[token];
        info.token = token;
        info.poolKey = poolKey;
        info.positionId = positionId;
        info.numPositions = numPositions;
        info.rewardBps = lockerConfig.rewardBps;
        info.rewardRecipients = lockerConfig.rewardRecipients;
        if (protocolSlotIndex != type(uint256).max) {
            _protocolSlotPlusOne[token] = protocolSlotIndex + 1;
        }

        emit TokenRewardAdded({
            token: token,
            poolKey: poolKey,
            poolSupply: poolSupply,
            positionId: positionId,
            numPositions: numPositions,
            rewardBps: lockerConfig.rewardBps,
            rewardRecipients: lockerConfig.rewardRecipients,
            tickLower: lockerConfig.tickLower,
            tickUpper: lockerConfig.tickUpper,
            positionBps: lockerConfig.positionBps
        });
    }

    function _checkConstants(address target) private view {
        bytes32 h;
        bool ok;
        if (target.code.length != 0) {
            bytes memory ret;
            (ok, ret) = target.staticcall(abi.encodeCall(IConstantsBound.constantsHash, ()));
            if (ok && ret.length >= 32) h = abi.decode(ret, (bytes32));
        }
        if (h != Constants.hash()) revert ConstantsMismatch(target);
    }

    /// @dev FT-10: every array length is checked, nothing is truncated.
    function _validateRewards(address[] calldata recipients, uint16[] calldata bps) private view {
        uint256 n = bps.length;
        if (n != recipients.length) revert MismatchedRewardArrays();
        if (n == 0) revert NoRewardRecipients();
        if (n > Constants.MAX_REWARD_PARTICIPANTS) revert TooManyRewardParticipants();
        uint256 total;
        for (uint256 i; i < n; ++i) {
            if (bps[i] == 0) revert ZeroRewardAmount();
            // LF-05: a zero recipient would strand its share; the locker
            // itself cannot receive eth and would trap the coin side.
            if (recipients[i] == address(0) || recipients[i] == address(this)) {
                revert ZeroAddress();
            }
            total += bps[i];
        }
        if (total != Constants.BPS) revert InvalidRewardBps();
    }

    function _validatePositions(
        IArtCoinsFactoryV2.LockerConfigV2 calldata cfg,
        int24 startTick,
        int24 tickSpacing
    ) private pure returns (uint256 n) {
        n = cfg.tickLower.length;
        if (n != cfg.tickUpper.length || n != cfg.positionBps.length) {
            revert MismatchedPositionArrays();
        }
        if (n > Constants.MAX_LP_POSITIONS) revert TooManyPositions();
        uint256 total;
        for (uint256 i; i < n; ++i) {
            int24 lo = cfg.tickLower[i];
            int24 hi = cfg.tickUpper[i];
            // ticks are given as if the coin were token0; the coin is always
            // token1 here, so the range is mirrored at mint time.
            if (
                lo >= hi || lo < TickMath.MIN_TICK || hi > TickMath.MAX_TICK
                    || lo % tickSpacing != 0 || hi % tickSpacing != 0 || lo < startTick
            ) revert InvalidTickRange(lo, hi);
            if (cfg.positionBps[i] == 0) revert InvalidPositionBps();
            total += cfg.positionBps[i];
        }
        // also rejects n == 0
        if (total != Constants.BPS) revert InvalidPositionBps();
    }

    function _mint(
        IArtCoinsFactoryV2.LockerConfigV2 calldata cfg,
        int24 tickIfToken0IsArtCoin,
        PoolKey calldata poolKey,
        uint256 poolSupply,
        address token
    ) private returns (uint256 positionId) {
        uint256 n = cfg.tickLower.length;
        bytes memory actions = new bytes(n + 1);
        bytes[] memory params = new bytes[](n + 1);
        uint160 sqrtStart = TickMath.getSqrtPriceAtTick(-tickIfToken0IsArtCoin);

        for (uint256 i; i < n; ++i) {
            actions[i] = bytes1(uint8(Actions.MINT_POSITION));
            uint256 amount1 = poolSupply * cfg.positionBps[i] / Constants.BPS;
            int24 tickLower = -cfg.tickUpper[i];
            int24 tickUpper = -cfg.tickLower[i];
            uint256 liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtStart,
                TickMath.getSqrtPriceAtTick(tickLower),
                TickMath.getSqrtPriceAtTick(tickUpper),
                0,
                amount1
            );
            // amount0Max 0: if the pool price is not the configured start the
            // mint needs eth and reverts.
            params[i] = abi.encode(
                poolKey,
                tickLower,
                tickUpper,
                liquidity,
                uint128(0),
                uint128(amount1),
                address(this),
                bytes("")
            );
        }
        actions[n] = bytes1(uint8(Actions.SETTLE_PAIR));
        params[n] = abi.encode(poolKey.currency0, poolKey.currency1);

        // D37: solady tokens (ArtCoinsTokenV2) fix the Permit2 allowance at
        // infinity and revert any approve to it; skip the erc20 approve and
        // its reset for them. Other tokens get the exact amount, reset after.
        bool fixedInfinite =
            IERC20(token).allowance(address(this), address(permit2)) == type(uint256).max;
        if (!fixedInfinite) SafeTransferLib.safeApprove(token, address(permit2), poolSupply);
        permit2.approve(
            token, address(positionManager), uint160(poolSupply), uint48(block.timestamp)
        );

        positionId = positionManager.nextTokenId();
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        if (!fixedInfinite) SafeTransferLib.safeApprove(token, address(permit2), 0);
        permit2.approve(token, address(positionManager), 0, 0);
    }

    // ── permissionless collect ────────────────────────────────────────────

    /// @inheritdoc IArtCoinsLpLockerV2
    /// @dev Pays `msg.sender` a keeper reward off the eth side (bounded by
    ///      `keeperRewardBps` and `keeperRewardCap`, skipped when the keeper
    ///      cannot take eth), then pushes every recipient share.
    function collectRewards(address token) external nonReentrant {
        _collectAndDistribute(token);
    }

    /// @dev Collect path shared by `collectRewards` and `setRewardRecipient`.
    ///      Refuses to run inside a foreign unlock (LF-01), pays the keeper, and
    ///      pushes every current recipient share. Callers hold the reentrancy
    ///      lock.
    function _collectAndDistribute(address token) private {
        TokenRewardInfoV2 storage info = _tokenRewards[token];
        uint256 n = info.numPositions;
        if (n == 0) revert TokenNotFound();
        // LF-01: never run inside a foreign unlock, where PositionManager
        // deltas are shared with whoever holds the lock.
        if (poolManager.isUnlocked()) revert PoolManagerUnlocked();

        PoolKey memory key = info.poolKey;
        (uint256 amount0, uint256 amount1) = _collect(key, info.positionId, n);
        emit RewardsCollected(token, amount0, amount1);

        if (amount0 > 0) amount0 -= _payKeeper(token, amount0);

        address escrow = feeEscrow;
        uint16[] memory bps = info.rewardBps;
        address[] memory recipients = info.rewardRecipients;
        uint256 last = bps.length - 1;
        uint256 sent0;
        uint256 sent1;
        for (uint256 i; i <= last; ++i) {
            uint256 s0 = i == last ? amount0 - sent0 : amount0 * bps[i] / Constants.BPS;
            uint256 s1 = i == last ? amount1 - sent1 : amount1 * bps[i] / Constants.BPS;
            sent0 += s0;
            sent1 += s1;
            address to = recipients[i];
            if (s0 > 0) {
                bool pushed = FeeDelivery.sendNative(escrow, to, s0, PUSH_GAS);
                emit RewardDelivered(token, address(0), to, s0, !pushed);
            }
            if (s1 > 0) {
                bool pushed = FeeDelivery.sendErc20(escrow, token, to, s1);
                emit RewardDelivered(token, token, to, s1, !pushed);
            }
        }
    }

    /// @dev Zero liquidity decreases on every position, then TAKE_PAIR, all
    ///      inside the PositionManager's own unlock. Amounts are this
    ///      contract's balance deltas.
    function _collect(PoolKey memory key, uint256 firstId, uint256 n)
        private
        returns (uint256 amount0, uint256 amount1)
    {
        bytes memory actions = new bytes(n + 1);
        bytes[] memory params = new bytes[](n + 1);
        for (uint256 i; i < n; ++i) {
            actions[i] = bytes1(uint8(Actions.DECREASE_LIQUIDITY));
            params[i] = abi.encode(firstId + i, uint256(0), uint128(0), uint128(0), bytes(""));
        }
        actions[n] = bytes1(uint8(Actions.TAKE_PAIR));
        params[n] = abi.encode(key.currency0, key.currency1, address(this));

        address coin = Currency.unwrap(key.currency1);
        uint256 b0 = address(this).balance;
        uint256 b1 = SafeTransferLib.balanceOf(coin, address(this));
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        amount0 = address(this).balance - b0;
        amount1 = SafeTransferLib.balanceOf(coin, address(this)) - b1;
    }

    /// @dev reward = min(amount * bps / BPS, cap), zero when it would take the
    ///      whole amount or the keeper rejects eth.
    function _payKeeper(address token, uint256 amount) private returns (uint256 reward) {
        reward = amount * keeperRewardBps / Constants.BPS;
        uint256 cap = keeperRewardCap;
        if (reward > cap) reward = cap;
        if (reward == 0 || reward >= amount) return 0;
        (bool ok,) = payable(msg.sender).call{value: reward}("");
        if (!ok) return 0;
        emit KeeperRewarded(msg.sender, token, address(0), reward);
    }

    // ── reads ─────────────────────────────────────────────────────────────

    /// @inheritdoc IArtCoinsLpLockerV2
    function tokenRewards(address token) external view returns (TokenRewardInfoV2 memory) {
        return _tokenRewards[token];
    }

    /// @inheritdoc IArtCoinsLpLockerV2
    function rewardRecipients(address token) external view returns (address[] memory) {
        return _tokenRewards[token].rewardRecipients;
    }

    /// @inheritdoc IArtCoinsLpLockerV2
    function rewardBps(address token) external view returns (uint16[] memory) {
        return _tokenRewards[token].rewardBps;
    }

    // ── coin admin ──────────────────────────────────────────────────────────

    /// @inheritdoc IArtCoinsLpLockerV2
    /// @dev Caller must be the coin's current admin. Reverts for every caller
    ///      once the admin is 0, which is how `lockRecipients` and renouncing
    ///      the admin freeze it. bps stay fixed. The protocol slot, recorded at
    ///      placement, stays frozen. `newRecipient` must be nonzero and not one
    ///      of the stack contracts that cannot hold a reward (see
    ///      `_rejectRewardRecipient`). Pending lp fees are collected and pushed
    ///      to the current recipients before the slot is repointed, so accrued
    ///      fees reach the old recipient.
    function setRewardRecipient(address token, uint256 index, address newRecipient)
        external
        nonReentrant
    {
        TokenRewardInfoV2 storage info = _tokenRewards[token];
        if (info.numPositions == 0) revert TokenNotFound();
        IArtCoinsTokenV2 t = IArtCoinsTokenV2(token);
        if (msg.sender != t.admin()) revert NotCoinAdmin();
        if (t.recipientsLocked()) revert RecipientsLocked();
        if (index >= info.rewardRecipients.length) revert RewardIndexOutOfRange();
        uint256 frozen = _protocolSlotPlusOne[token];
        if (frozen != 0 && index == frozen - 1) revert ProtocolSlotFrozen();
        if (newRecipient == address(0)) revert ZeroAddress();
        _rejectRewardRecipient(token, info.poolKey, newRecipient);

        _collectAndDistribute(token);

        address old = info.rewardRecipients[index];
        info.rewardRecipients[index] = newRecipient;
        emit RewardRecipientSet(token, index, old, newRecipient);
    }

    /// @dev Reverts `RecipientCannotReceive` when `r` is a stack contract that
    ///      cannot hold a reward. Resolves the factory from the coin, the token
    ///      deployer from the factory and the mev module from the pool's hook;
    ///      an unreachable read is skipped.
    function _rejectRewardRecipient(address token, PoolKey memory key, address r) private view {
        if (
            r == token || r == address(this) || r == feeEscrow || r == address(key.hooks)
                || r == address(poolManager) || r == address(positionManager)
        ) revert RecipientCannotReceive(r);
        address factory = IArtCoinsTokenV2(token).launcher();
        if (r == factory) revert RecipientCannotReceive(r);
        // fail closed: a lookup that cannot be read refuses the change.
        try IFactoryTokenDeployer(factory).tokenDeployer() returns (address dep) {
            if (r == dep) revert RecipientCannotReceive(r);
        } catch {
            revert RecipientCheckFailed();
        }
        try IArtCoinsHookV2(address(key.hooks)).poolInfo(key.toId()) returns (
            IArtCoinsHookV2.PoolInfo memory pinfo
        ) {
            if (r == pinfo.mevModule) revert RecipientCannotReceive(r);
        } catch {
            revert RecipientCheckFailed();
        }
        // the pool hook's escrow may differ from this locker's; reject it too.
        try IArtCoinsHookV2(address(key.hooks)).globals() returns (
            IArtCoinsHookV2.HookGlobals memory g
        ) {
            if (r == g.feeEscrow) revert RecipientCannotReceive(r);
        } catch {
            revert RecipientCheckFailed();
        }
    }

    /// @inheritdoc IArtCoinsLpLockerV2
    function protocolSlotIndex(address token) external view returns (bool exists, uint256 index) {
        uint256 plus1 = _protocolSlotPlusOne[token];
        if (plus1 == 0) return (false, 0);
        return (true, plus1 - 1);
    }

    // ── owner ─────────────────────────────────────────────────────────────

    /// @inheritdoc IArtCoinsLpLockerV2
    function setKeeperRewardBps(uint256 newBps) external onlyOwner {
        if (newBps > Constants.LOCKER_KEEPER_BPS_MAX) {
            revert KeeperRewardBpsOutOfBounds(newBps, Constants.LOCKER_KEEPER_BPS_MAX);
        }
        emit KeeperRewardBpsSet(keeperRewardBps, newBps);
        keeperRewardBps = newBps;
    }

    /// @inheritdoc IArtCoinsLpLockerV2
    function setKeeperRewardCap(uint256 newCap) external onlyOwner {
        if (newCap < Constants.LOCKER_KEEPER_CAP_MIN || newCap > Constants.LOCKER_KEEPER_CAP_MAX) {
            revert KeeperRewardCapOutOfBounds(
                newCap, Constants.LOCKER_KEEPER_CAP_MIN, Constants.LOCKER_KEEPER_CAP_MAX
            );
        }
        emit KeeperRewardCapSet(keeperRewardCap, newCap);
        keeperRewardCap = newCap;
    }

    /// @inheritdoc IArtCoinsLpLockerV2
    /// @dev The new escrow must report the same `constantsHash()` and must
    ///      list this locker as a depositor before collects can fall back to it.
    function setFeeEscrow(address escrow) external onlyOwner {
        _setFeeEscrow(escrow);
    }

    function _setFeeEscrow(address escrow) private {
        if (escrow == address(0)) revert ZeroAddress();
        _checkConstants(escrow);
        emit FeeEscrowSet(feeEscrow, escrow);
        feeEscrow = escrow;
    }

    /// @inheritdoc IArtCoinsLpLockerV2
    function setLauncher(address launcher, bool enabled) external onlyOwner {
        if (launcher == address(0)) revert ZeroAddress();
        isLauncher[launcher] = enabled;
        emit LauncherSet(launcher, enabled);
    }

    /// @inheritdoc IArtCoinsLpLockerV2
    /// @dev Locked against reentry, so it cannot run inside a collect while
    ///      shares are in flight. Lp nfts have no exit: the PositionManager is
    ///      refused as a token.
    function rescue(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (token == address(positionManager)) revert RescueForbidden();
        if (token == address(0)) {
            (bool ok,) = payable(to).call{value: amount}("");
            if (!ok) revert EthTransferFailed();
        } else {
            SafeTransferLib.safeTransfer(token, to, amount);
        }
        emit Rescued(token, to, amount);
    }
}
