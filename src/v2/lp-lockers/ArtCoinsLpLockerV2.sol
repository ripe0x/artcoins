// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Constants} from "../../Constants.sol";
import {IArtCoinsFactoryV2} from "../interfaces/IArtCoinsFactoryV2.sol";
import {IArtCoinsLpLockerV2} from "../interfaces/IArtCoinsLpLockerV2.sol";
import {IConstantsBound} from "../interfaces/IConstantsBound.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title  ArtCoinsLpLockerV2
/// @notice Holds each v2 coin's launch liquidity. The positions are minted to
///         this contract and have no decrease path. v2 pools charge no lp fee,
///         so the positions accrue nothing.
/// @dev    Native eth paired pools only: currency0 is eth, currency1 is the
///         coin. The locker holds nothing between calls; any balance is stray
///         and rescuable. The position nfts are not rescuable.
contract ArtCoinsLpLockerV2 is IArtCoinsLpLockerV2, Ownable2Step, ReentrancyGuardTransient {
    /// @inheritdoc IArtCoinsLpLockerV2
    uint16 public constant STACK_VERSION = Constants.STACK_VERSION;

    /// @notice PositionManager that holds the launch positions.
    IPositionManager public immutable positionManager;
    /// @notice Uniswap v4 PoolManager of `positionManager`.
    IPoolManager public immutable poolManager;
    /// @notice Permit2 used to approve coin transfers into `positionManager`.
    IPermit2 public immutable permit2;

    /// @inheritdoc IArtCoinsLpLockerV2
    mapping(address launcher => bool) public isLauncher;

    mapping(address token => LockedLiquidity) internal _locked;

    /// @param owner_           Owner (Ownable2Step).
    /// @param positionManager_ Uniswap v4 PositionManager.
    /// @param permit2_         Permit2.
    constructor(address owner_, address positionManager_, address permit2_) Ownable(owner_) {
        if (positionManager_ == address(0) || permit2_ == address(0)) revert ZeroAddress();
        positionManager = IPositionManager(positionManager_);
        poolManager = positionManager.poolManager();
        permit2 = IPermit2(permit2_);
    }

    /// @inheritdoc IConstantsBound
    function constantsHash() external pure returns (bytes32) {
        return Constants.hash();
    }

    // ── launcher ──────────────────────────────────────────────────────────

    /// @inheritdoc IArtCoinsLpLockerV2
    /// @dev Pulls `poolSupply` of `token` from the launcher (prior approval) and
    ///      mints coin only positions below the starting price. Rounding dust
    ///      of the coin is sent to `Constants.DEAD`.
    function placeLiquidity(
        IArtCoinsFactoryV2.LockerConfigV2 calldata lockerConfig,
        IArtCoinsFactoryV2.PoolConfigV2 calldata poolConfig,
        PoolKey calldata poolKey,
        uint256 poolSupply,
        address token
    ) external nonReentrant returns (uint256 positionId) {
        if (!isLauncher[msg.sender]) revert NotLauncher();
        if (token == address(0)) revert ZeroAddress();
        if (_locked[token].numPositions != 0) revert TokenAlreadyLocked();

        address hook = address(poolKey.hooks);
        if (
            !poolKey.currency0.isAddressZero() || Currency.unwrap(poolKey.currency1) != token
                || hook != poolConfig.hook || poolKey.tickSpacing != poolConfig.tickSpacing
        ) revert UnsupportedPoolKey();
        _checkConstants(hook);

        uint256 numPositions =
            _validatePositions(lockerConfig, poolConfig.tickIfToken0IsCoin, poolKey.tickSpacing);

        uint256 balBefore = SafeTransferLib.balanceOf(token, address(this));
        SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), poolSupply);

        positionId = _mint(lockerConfig, poolConfig.tickIfToken0IsCoin, poolKey, poolSupply, token);

        // send any coin left after placement (rounding dust) to the burn sink
        uint256 balAfter = SafeTransferLib.balanceOf(token, address(this));
        if (balAfter > balBefore) {
            SafeTransferLib.safeTransfer(token, Constants.DEAD, balAfter - balBefore);
        }

        _locked[token] = LockedLiquidity({
            token: token, poolKey: poolKey, positionId: positionId, numPositions: numPositions
        });

        emit LiquidityLocked({
            token: token,
            poolKey: poolKey,
            poolSupply: poolSupply,
            positionId: positionId,
            numPositions: numPositions,
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
        int24 tickIfToken0IsCoin,
        PoolKey calldata poolKey,
        uint256 poolSupply,
        address token
    ) private returns (uint256 positionId) {
        uint256 n = cfg.tickLower.length;
        bytes memory actions = new bytes(n + 1);
        bytes[] memory params = new bytes[](n + 1);
        uint160 sqrtStart = TickMath.getSqrtPriceAtTick(-tickIfToken0IsCoin);

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

        // solady tokens (ArtCoinsTokenV2) fix the Permit2 allowance at
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

    // ── reads ─────────────────────────────────────────────────────────────

    /// @inheritdoc IArtCoinsLpLockerV2
    function lockedLiquidity(address token) external view returns (LockedLiquidity memory) {
        return _locked[token];
    }

    // ── owner ─────────────────────────────────────────────────────────────

    /// @inheritdoc IArtCoinsLpLockerV2
    function setLauncher(address launcher, bool enabled) external onlyOwner {
        if (launcher == address(0)) revert ZeroAddress();
        isLauncher[launcher] = enabled;
        emit LauncherSet(launcher, enabled);
    }

    /// @inheritdoc IArtCoinsLpLockerV2
    /// @dev Lp nfts have no exit: the PositionManager is refused as a token.
    function rescue(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (token == address(positionManager)) revert RescueForbidden();
        if (token == address(0)) {
            (bool ok,) = payable(to).call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            SafeTransferLib.safeTransfer(token, to, amount);
        }
        emit Rescued(token, to, amount);
    }
}
