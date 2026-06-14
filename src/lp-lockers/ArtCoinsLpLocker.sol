// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsFactory} from "../interfaces/IArtCoinsFactory.sol";
import {IArtCoinsFeeEscrow} from "../interfaces/IArtCoinsFeeEscrow.sol";
import {IArtCoinsLpLocker} from "../interfaces/IArtCoinsLpLocker.sol";
import {IArtCoinsLpLockerMultiple} from "./interfaces/IArtCoinsLpLockerMultiple.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

/// @title  ArtCoinsLpLocker
/// @notice Currency-agnostic LP locker with first-class native-ETH support:
///         pools paired with native ETH (`Currency.wrap(address(0))`) have
///         their ETH-side fees collected via balance deltas and forwarded to
///         `ArtCoinsFeeEscrow` via `storeFeesNative{value:}`.
/// @dev    All native-ETH branches gate on `Currency.unwrap(currency) == address(0)`.
contract ArtCoinsLpLocker is IArtCoinsLpLockerMultiple, ReentrancyGuard, Ownable {
    using TickMath for int24;

    /// @notice Locker version.
    string public constant version = "1";

    /// @notice BPS denominator (10,000 = 100%).
    uint256 public constant BASIS_POINTS = 10_000;
    /// @notice Maximum number of reward recipients per token.
    uint256 public constant MAX_REWARD_PARTICIPANTS = 7;
    /// @notice Maximum number of LP positions per token. 14 so PERMANENT
    ///         COLLECTION can carry its thin-floor taper PLUS two concentrated
    ///         high-FDV tail positions ($30M–$300M FDV coverage).
    uint256 public constant MAX_LP_POSITIONS = 14;

    /// @notice Upper bound on `keeperRewardBps`. Bounded narrow so a future
    ///         owner setter cannot meaningfully grief recipients — at the
    ///         max value, recipients still receive 98% of paired-side fees.
    uint256 public constant KEEPER_REWARD_BPS_MAX = 200; // 2%
    /// @notice Lower bound on `keeperRewardCap`. Even a fully-discounted gas
    ///         market should produce viable keeper economics at this cap.
    uint256 public constant KEEPER_REWARD_CAP_MIN = 0.001 ether;
    /// @notice Upper bound on `keeperRewardCap`. Generous enough that the
    ///         owner can adapt to high-gas regimes; tight enough that a
    ///         single call can never claim more than 0.05 ETH from
    ///         recipients regardless of accumulation size.
    uint256 public constant KEEPER_REWARD_CAP_MAX = 0.05 ether;

    /// @notice Uniswap v4 position manager.
    IPositionManager public immutable positionManager;
    /// @notice Permit2 instance used to grant approvals to the position manager.
    IPermit2 public immutable permit2;
    /// @notice Fee escrow that holds distributed rewards (ERC20 + native ETH).
    IArtCoinsFeeEscrow public immutable feeLocker;
    /// @notice Authorized factory.
    address public immutable factory;

    /// @notice Keeper-reward bps applied to the paired-side fee amount on
    ///         each `collectRewards` call. Paid to `msg.sender`. Bounded by
    ///         `KEEPER_REWARD_BPS_MAX`. Default 50 (0.5%).
    uint256 public keeperRewardBps = 50;
    /// @notice Absolute cap on the keeper reward per call. Once accrued
    ///         paired-side fees are large enough that bps × amount exceeds
    ///         the cap, the keeper takes exactly the cap and recipients keep
    ///         everything above. Default 0.01 ETH. Bounded by
    ///         `KEEPER_REWARD_CAP_MIN` and `KEEPER_REWARD_CAP_MAX`.
    uint256 public keeperRewardCap = 0.01 ether;

    mapping(address token => TokenRewardInfo tokenRewardInfo) internal _tokenRewards;

    /// @param owner_ Initial owner.
    /// @param factory_ Address of the ArtCoins token factory.
    /// @param feeLocker_ Address of the `ArtCoinsFeeEscrow` (must support native-ETH path).
    /// @param positionManager_ Uniswap v4 position manager address.
    /// @param permit2_ Permit2 address.
    constructor(
        address owner_,
        address factory_,
        address feeLocker_,
        address positionManager_,
        address permit2_
    ) Ownable(owner_) {
        factory = factory_;
        feeLocker = IArtCoinsFeeEscrow(feeLocker_);
        positionManager = IPositionManager(positionManager_);
        permit2 = IPermit2(permit2_);
    }

    /// @dev Restricts a function to the bound `factory`.
    modifier onlyFactory() {
        if (msg.sender != factory) {
            revert Unauthorized();
        }
        _;
    }

    /// @notice Accept native ETH from PoolManager.take during fee collection
    ///         on native-ETH-paired pools. No crediting happens here; the
    ///         delta arithmetic in `_bringFeesIntoContract` accounts for it.
    receive() external payable {}

    // ─── keeper-reward setters ──────────────────────────────────────────

    event KeeperRewarded(
        address indexed keeper, address indexed token, address indexed rewardToken, uint256 amount
    );
    event KeeperRewardBpsUpdated(uint256 oldBps, uint256 newBps);
    event KeeperRewardCapUpdated(uint256 oldCap, uint256 newCap);

    error KeeperRewardBpsOutOfBounds(uint256 supplied, uint256 max);
    error KeeperRewardCapOutOfBounds(uint256 supplied, uint256 min, uint256 max);

    /// @notice Updates the keeper-reward bps applied to paired-side fees on
    ///         each `collectRewards` call. Owner only. Bounded by
    ///         `KEEPER_REWARD_BPS_MAX` so the owner can never grief
    ///         recipients beyond a small fixed ceiling.
    function setKeeperRewardBps(uint256 newBps) external onlyOwner {
        if (newBps > KEEPER_REWARD_BPS_MAX) {
            revert KeeperRewardBpsOutOfBounds(newBps, KEEPER_REWARD_BPS_MAX);
        }
        uint256 old = keeperRewardBps;
        keeperRewardBps = newBps;
        emit KeeperRewardBpsUpdated(old, newBps);
    }

    /// @notice Updates the absolute per-call cap on the keeper reward. Owner
    ///         only. Bounded by `KEEPER_REWARD_CAP_MIN` and
    ///         `KEEPER_REWARD_CAP_MAX`. The lower bound prevents the owner
    ///         from setting the cap so low that keepers stop calling.
    function setKeeperRewardCap(uint256 newCap) external onlyOwner {
        if (newCap < KEEPER_REWARD_CAP_MIN || newCap > KEEPER_REWARD_CAP_MAX) {
            revert KeeperRewardCapOutOfBounds(newCap, KEEPER_REWARD_CAP_MIN, KEEPER_REWARD_CAP_MAX);
        }
        uint256 old = keeperRewardCap;
        keeperRewardCap = newCap;
        emit KeeperRewardCapUpdated(old, newCap);
    }

    /// @dev Computes and pays the keeper reward off the paired-side fee
    ///      amount. Returns the actual reward paid (which is subtracted
    ///      from the paired-side amount before distribution to recipients);
    ///      returns 0 if the reward was either too small to pay or the
    ///      keeper couldn't accept native ETH.
    ///
    ///      Reward sizing mirrors the codebase's standard pattern
    ///      (`BurnRouter.KEEPER_REWARD_BPS` /
    ///      `FeeAutoSwapper.KEEPER_REWARD_BPS`): `bps * paired / 10_000`,
    ///      clamped to `cap`, zeroed if it would consume the entire
    ///      paired-side amount (pathological tiny-claim guard).
    ///
    ///      Native-ETH delivery uses a low-level `call`. If the keeper
    ///      can't accept ETH (non-payable contract, locked recipient),
    ///      `collectRewards` does NOT revert — the reward is silently
    ///      skipped and recipients keep their full share. This makes
    ///      `collectRewards` safe to call from any contract context (e.g.,
    ///      tests, multisigs, integration harnesses) without forcing the
    ///      caller to be payable. Real keepers (EOAs, MEV bots) accept
    ///      ETH and earn the reward.
    function _payKeeperReward(address pairedToken, uint256 pairedAmount)
        internal
        returns (uint256 reward)
    {
        reward = (pairedAmount * keeperRewardBps) / BASIS_POINTS;
        if (reward > keeperRewardCap) reward = keeperRewardCap;
        if (reward >= pairedAmount) reward = 0;
        if (reward == 0) return 0;

        if (pairedToken == address(0)) {
            (bool ok,) = payable(msg.sender).call{value: reward}("");
            if (!ok) return 0;
        } else {
            SafeERC20.safeTransfer(IERC20(pairedToken), msg.sender, reward);
        }
    }

    /// @inheritdoc IArtCoinsLpLocker
    function tokenRewards(address token) external view returns (TokenRewardInfo memory) {
        return _tokenRewards[token];
    }

    /// @inheritdoc IArtCoinsLpLocker
    function placeLiquidity(
        IArtCoinsFactory.LockerConfig memory lockerConfig,
        IArtCoinsFactory.PoolConfig memory poolConfig,
        PoolKey memory poolKey,
        uint256 poolSupply,
        address token
    ) external onlyFactory nonReentrant returns (uint256 positionId) {
        // ensure that we don't already have a reward for this token
        if (_tokenRewards[token].positionId != 0) {
            revert TokenAlreadyHasRewards();
        }

        TokenRewardInfo memory tokenRewardInfo = TokenRewardInfo({
            token: token,
            poolKey: poolKey,
            positionId: 0,
            numPositions: lockerConfig.tickLower.length,
            rewardBps: lockerConfig.rewardBps,
            rewardAdmins: lockerConfig.rewardAdmins,
            rewardRecipients: lockerConfig.rewardRecipients
        });

        if (
            tokenRewardInfo.rewardBps.length != tokenRewardInfo.rewardAdmins.length
                || tokenRewardInfo.rewardBps.length != tokenRewardInfo.rewardRecipients.length
        ) {
            revert MismatchedRewardArrays();
        }

        if (tokenRewardInfo.rewardBps.length > MAX_REWARD_PARTICIPANTS) {
            revert TooManyRewardParticipants();
        }

        if (tokenRewardInfo.rewardBps.length == 0) {
            revert NoRewardRecipients();
        }

        uint16 totalRewards = 0;
        for (uint256 i = 0; i < tokenRewardInfo.rewardBps.length; i++) {
            totalRewards += tokenRewardInfo.rewardBps[i];
            if (tokenRewardInfo.rewardBps[i] == 0) {
                revert ZeroRewardAmount();
            }
        }
        if (totalRewards != BASIS_POINTS) {
            revert InvalidRewardBps();
        }

        for (uint256 i = 0; i < tokenRewardInfo.rewardBps.length; i++) {
            if (
                tokenRewardInfo.rewardAdmins[i] == address(0)
                    || tokenRewardInfo.rewardRecipients[i] == address(0)
            ) {
                revert ZeroRewardAddress();
            }
        }

        IERC20(token).transferFrom(msg.sender, address(this), poolSupply);

        positionId = _mintLiquidity(poolConfig, lockerConfig, poolKey, poolSupply, token);

        tokenRewardInfo.positionId = positionId;
        _tokenRewards[token] = tokenRewardInfo;

        emit TokenRewardAdded({
            token: tokenRewardInfo.token,
            poolKey: tokenRewardInfo.poolKey,
            poolSupply: poolSupply,
            positionId: tokenRewardInfo.positionId,
            numPositions: tokenRewardInfo.numPositions,
            rewardBps: tokenRewardInfo.rewardBps,
            rewardAdmins: tokenRewardInfo.rewardAdmins,
            rewardRecipients: tokenRewardInfo.rewardRecipients,
            tickLower: lockerConfig.tickLower,
            tickUpper: lockerConfig.tickUpper,
            positionBps: lockerConfig.positionBps
        });
    }

    function _mintLiquidity(
        IArtCoinsFactory.PoolConfig memory poolConfig,
        IArtCoinsFactory.LockerConfig memory lockerConfig,
        PoolKey memory poolKey,
        uint256 poolSupply,
        address token
    ) internal returns (uint256 positionId) {
        if (
            lockerConfig.tickLower.length != lockerConfig.tickUpper.length
                || lockerConfig.tickLower.length != lockerConfig.positionBps.length
        ) {
            revert MismatchedPositionInfos();
        }

        if (lockerConfig.tickLower.length == 0) {
            revert NoPositions();
        }

        if (lockerConfig.tickLower.length > MAX_LP_POSITIONS) {
            revert TooManyPositions();
        }

        uint256 positionBpsTotal = 0;
        for (uint256 i = 0; i < lockerConfig.tickLower.length; i++) {
            if (lockerConfig.tickLower[i] > lockerConfig.tickUpper[i]) {
                revert TicksBackwards();
            }
            if (
                lockerConfig.tickLower[i] < TickMath.MIN_TICK
                    || lockerConfig.tickUpper[i] > TickMath.MAX_TICK
            ) {
                revert TicksOutOfTickBounds();
            }
            if (
                lockerConfig.tickLower[i] % poolConfig.tickSpacing != 0
                    || lockerConfig.tickUpper[i] % poolConfig.tickSpacing != 0
            ) {
                revert TicksNotMultipleOfTickSpacing();
            }
            if (lockerConfig.tickLower[i] < poolConfig.tickIfToken0IsArtCoins) {
                revert TickRangeLowerThanStartingTick();
            }

            positionBpsTotal += lockerConfig.positionBps[i];
        }
        if (positionBpsTotal != BASIS_POINTS) {
            revert InvalidPositionBps();
        }

        bool token0IsArtCoins = token < poolConfig.pairedToken;

        bytes[] memory params = new bytes[](lockerConfig.tickLower.length + 1);
        bytes memory actions;

        int24 startingTick = token0IsArtCoins
            ? poolConfig.tickIfToken0IsArtCoins
            : -poolConfig.tickIfToken0IsArtCoins;

        for (uint256 i = 0; i < lockerConfig.tickLower.length; i++) {
            actions = abi.encodePacked(actions, uint8(Actions.MINT_POSITION));

            uint256 tokenAmount = poolSupply * lockerConfig.positionBps[i] / BASIS_POINTS;
            uint256 amount0 = token0IsArtCoins ? tokenAmount : 0;
            uint256 amount1 = token0IsArtCoins ? 0 : tokenAmount;

            int24 tickLower_ =
                token0IsArtCoins ? lockerConfig.tickLower[i] : -lockerConfig.tickLower[i];
            int24 tickUpper_ =
                token0IsArtCoins ? lockerConfig.tickUpper[i] : -lockerConfig.tickUpper[i];
            int24 tickLower = token0IsArtCoins ? tickLower_ : tickUpper_;
            int24 tickUpper = token0IsArtCoins ? tickUpper_ : tickLower_;
            uint160 lowerSqrtPrice = TickMath.getSqrtPriceAtTick(tickLower);
            uint160 upperSqrtPrice = TickMath.getSqrtPriceAtTick(tickUpper);

            uint256 liquidity = LiquidityAmounts.getLiquidityForAmounts(
                startingTick.getSqrtPriceAtTick(), lowerSqrtPrice, upperSqrtPrice, amount0, amount1
            );

            params[i] = abi.encode(
                poolKey,
                tickLower,
                tickUpper,
                liquidity,
                amount0,
                amount1,
                address(this),
                abi.encode(address(this))
            );
        }

        actions = abi.encodePacked(actions, uint8(Actions.SETTLE_PAIR));
        params[lockerConfig.tickLower.length] = abi.encode(poolKey.currency0, poolKey.currency1);

        {
            IERC20(token).approve(address(permit2), type(uint256).max);
            permit2.approve(
                token, address(positionManager), uint160(poolSupply), uint48(block.timestamp)
            );
        }

        positionId = positionManager.nextTokenId();
        // Forward any ETH attached by the factory (for native-ETH-paired pools
        // where the initial liquidity provision needs paired-side ETH). For
        // pure single-sided launches, `msg.value` is 0 and this is a no-op.
        positionManager.modifyLiquidities{value: msg.value}(
            abi.encode(actions, params), block.timestamp
        );
    }

    /// @inheritdoc IArtCoinsLpLocker
    /// @dev For use from inside a hook callback where the V4 PoolManager is
    ///      already unlocked. NOT called by the hook. The function remains in
    ///      the contract surface for use by hook variants or pool extensions
    ///      that want to drive distribution from within an unlock context.
    ///
    ///      **Reward delivery to contract callers.** Like `collectRewards`,
    ///      this path pays the keeper reward to `msg.sender` in the
    ///      paired-side currency. If the calling contract has a payable
    ///      receive (native-ETH path), it will accept the ETH but holds no
    ///      sweep path by default — the contract that calls this MUST have
    ///      an intentional sink, sweep, or forwarding logic for the ETH.
    ///      For WETH-paired pools, the reward arrives as an ERC20 balance
    ///      with the same sweep-or-strand consideration. If the caller is
    ///      an unintended downstream contract (e.g., an extension fired
    ///      from within an afterSwap), the reward could land in a contract
    ///      with no withdrawal surface and strand. If this matters for
    ///      your integration, consider taking an explicit recipient
    ///      argument upstream of this call.
    function collectRewardsWithoutUnlock(address token) external nonReentrant {
        _collectRewards(token, true);
    }

    /// @inheritdoc IArtCoinsLpLocker
    /// @dev Permissionless entry point. Pays the caller a keeper reward off
    ///      the paired-side fees before distributing the remainder to the
    ///      configured `rewardRecipients`. See `_payKeeperReward` for the
    ///      reward formula and the native-vs-ERC20 delivery semantics.
    function collectRewards(address token) external nonReentrant {
        _collectRewards(token, false);
    }

    function _collectRewards(address token, bool withoutUnlock) internal {
        TokenRewardInfo memory tokenRewardInfo = _tokenRewards[token];

        (uint256 amount0, uint256 amount1) = _bringFeesIntoContract(
            tokenRewardInfo.poolKey,
            tokenRewardInfo.positionId,
            tokenRewardInfo.numPositions,
            withoutUnlock
        );

        address rewardToken0 = Currency.unwrap(tokenRewardInfo.poolKey.currency0);
        address rewardToken1 = Currency.unwrap(tokenRewardInfo.poolKey.currency1);

        // Pay msg.sender a keeper reward off the paired-side fees. The
        // paired side is whichever currency is NOT the art coin (`token`).
        // Pays in that currency directly. Reduces the amount distributed to
        // recipients by the reward.
        bool token0IsArtCoin = (rewardToken0 == token);
        if (token0IsArtCoin) {
            uint256 reward = _payKeeperReward(rewardToken1, amount1);
            if (reward > 0) {
                amount1 -= reward;
                emit KeeperRewarded(msg.sender, token, rewardToken1, reward);
            }
        } else {
            uint256 reward = _payKeeperReward(rewardToken0, amount0);
            if (reward > 0) {
                amount0 -= reward;
                emit KeeperRewarded(msg.sender, token, rewardToken0, reward);
            }
        }

        uint256[] memory rewards0 = new uint256[](tokenRewardInfo.rewardBps.length);
        uint256[] memory rewards1 = new uint256[](tokenRewardInfo.rewardBps.length);
        uint256 reward0Total = 0;
        uint256 reward1Total = 0;

        for (uint256 i = 0; i < tokenRewardInfo.rewardBps.length - 1; i++) {
            rewards0[i] = uint256(tokenRewardInfo.rewardBps[i]) * amount0 / BASIS_POINTS;
            rewards1[i] = uint256(tokenRewardInfo.rewardBps[i]) * amount1 / BASIS_POINTS;
            reward0Total += rewards0[i];
            reward1Total += rewards1[i];
        }
        rewards0[tokenRewardInfo.rewardBps.length - 1] = amount0 - reward0Total;
        rewards1[tokenRewardInfo.rewardBps.length - 1] = amount1 - reward1Total;

        for (uint256 i = 0; i < tokenRewardInfo.rewardBps.length; i++) {
            if (rewards0[i] > 0) {
                _depositReward(rewardToken0, tokenRewardInfo.rewardRecipients[i], rewards0[i]);
            }
            if (rewards1[i] > 0) {
                _depositReward(rewardToken1, tokenRewardInfo.rewardRecipients[i], rewards1[i]);
            }
        }

        emit ClaimedRewards(tokenRewardInfo.token, amount0, amount1, rewards0, rewards1);
    }

    /// @dev Routes a reward deposit to the fee escrow based on currency type.
    ///      Native ETH uses the payable `storeFeesNative` path; ERC20 uses
    ///      `storeFees` with an approval grant.
    function _depositReward(address rewardToken, address recipient, uint256 amount) internal {
        if (rewardToken == address(0)) {
            feeLocker.storeFeesNative{value: amount}(recipient);
        } else {
            SafeERC20.forceApprove(IERC20(rewardToken), address(feeLocker), amount);
            feeLocker.storeFees(recipient, rewardToken, amount);
        }
    }

    function _bringFeesIntoContract(
        PoolKey memory poolKey,
        uint256 positionId,
        uint256 numPositions,
        bool withoutUnlock
    ) internal returns (uint256 amount0, uint256 amount1) {
        bytes memory actions;
        bytes[] memory params = new bytes[](numPositions + 1);

        for (uint256 i = 0; i < numPositions; i++) {
            actions = abi.encodePacked(actions, uint8(Actions.DECREASE_LIQUIDITY));
            params[i] = abi.encode(positionId + i, 0, 0, 0, abi.encode());
        }

        Currency currency0 = poolKey.currency0;
        Currency currency1 = poolKey.currency1;
        actions = abi.encodePacked(actions, uint8(Actions.TAKE_PAIR));
        params[numPositions] = abi.encode(currency0, currency1, address(this));

        // Snapshot balances on both currencies (native or ERC20).
        uint256 balance0Before = _currencyBalance(currency0);
        uint256 balance1Before = _currencyBalance(currency1);

        if (withoutUnlock) {
            positionManager.modifyLiquiditiesWithoutUnlock(actions, params);
        } else {
            positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        }

        uint256 balance0After = _currencyBalance(currency0);
        uint256 balance1After = _currencyBalance(currency1);

        return (balance0After - balance0Before, balance1After - balance1Before);
    }

    /// @dev Reads this contract's balance of `currency`. Native ETH
    ///      (`address(0)` after unwrap) returns `address(this).balance`;
    ///      ERC20s return `IERC20.balanceOf(this)`.
    function _currencyBalance(Currency currency) internal view returns (uint256) {
        address unwrapped = Currency.unwrap(currency);
        if (unwrapped == address(0)) {
            return address(this).balance;
        }
        return IERC20(unwrapped).balanceOf(address(this));
    }

    /// @notice Replaces the reward recipient at `rewardIndex` for a token.
    ///         Only the slot's admin may call.
    function updateRewardRecipient(address token, uint256 rewardIndex, address newRecipient)
        external
    {
        TokenRewardInfo storage tokenRewardInfo = _tokenRewards[token];

        if (msg.sender != tokenRewardInfo.rewardAdmins[rewardIndex]) {
            revert Unauthorized();
        }

        address oldRecipient = tokenRewardInfo.rewardRecipients[rewardIndex];
        tokenRewardInfo.rewardRecipients[rewardIndex] = newRecipient;

        emit RewardRecipientUpdated(token, rewardIndex, oldRecipient, newRecipient);
    }

    /// @notice Replaces the reward admin at `rewardIndex` for a token.
    ///         Only the slot's current admin may call.
    function updateRewardAdmin(address token, uint256 rewardIndex, address newAdmin) external {
        TokenRewardInfo storage tokenRewardInfo = _tokenRewards[token];

        if (msg.sender != tokenRewardInfo.rewardAdmins[rewardIndex]) {
            revert Unauthorized();
        }

        address oldAdmin = tokenRewardInfo.rewardAdmins[rewardIndex];
        tokenRewardInfo.rewardAdmins[rewardIndex] = newAdmin;

        emit RewardAdminUpdated(token, rewardIndex, oldAdmin, newAdmin);
    }

    /// @notice ERC-721 receiver for incoming LP NFTs; restricted to factory transfers.
    function onERC721Received(address, address from, uint256 id, bytes calldata)
        external
        returns (bytes4)
    {
        if (from != factory) {
            revert Unauthorized();
        }

        emit Received(from, id);
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Sweeps ETH held by the locker to a recipient. Owner only.
    function withdrawETH(address recipient) public onlyOwner nonReentrant {
        payable(recipient).transfer(address(this).balance);
    }

    /// @notice Sweeps an ERC20 balance held by the locker to a recipient. Owner only.
    function withdrawERC20(address token, address recipient) public onlyOwner nonReentrant {
        IERC20 token_ = IERC20(token);
        SafeERC20.safeTransfer(token_, recipient, token_.balanceOf(address(this)));
    }

    /// @notice ERC-165 introspection.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC721Receiver).interfaceId
            || interfaceId == type(IArtCoinsLpLocker).interfaceId;
    }
}
