// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// independent review v2-b: periphery against the real v2 hook on a mainnet fork.
// run: /tmp/claude-0/forge.sh test --match-path "test/v2/review-v2/b/**" \
//   --skip "test/v2/harness/**" --skip "test/v2/review/**" --skip script \
//   --skip src/v2/ArtCoinsFactoryV2.sol --skip "test/v2/FactoryV2*" --skip "test/v2/mocks/FactoryV2*" -vv
// after the fixes (D39, D40, D50) the test_V2Bxx_* tests are regressions: they
// PASS by asserting the fixed outcome. the original attack is kept in a comment
// above each one. tests named test_holds_* PASS when the claim holds.

import {HookV2ForkBase} from "../../mocks/HookV2ForkBase.sol";

import {Constants} from "../../../../src/Constants.sol";
import {ArtCoinsTokenV2} from "../../../../src/v2/ArtCoinsTokenV2.sol";
import {FeeAutoSwapperV2} from "../../../../src/v2/FeeAutoSwapperV2.sol";
import {ArtCoinsUniv4EthDevBuyV2} from "../../../../src/v2/extensions/ArtCoinsUniv4EthDevBuyV2.sol";
import {IArtCoinsFactoryV2} from "../../../../src/v2/interfaces/IArtCoinsFactoryV2.sol";
import {IBurnRouterV2} from "../../../../src/v2/interfaces/IBurnRouterV2.sol";
import {BurnRouterV2} from "../../../../src/v2/protocol-fee/BurnRouterV2.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract V2BSink {
    receive() external payable {}
}

contract V2BPeripheryForkTest is HookV2ForkBase {
    address internal keeper = makeAddr("v2b-keeper");
    address internal griefer = makeAddr("v2b-griefer");

    // ── helpers ───────────────────────────────────────────────────────────

    function _launchWith(uint8 mode, uint24 baseline)
        internal
        returns (PoolKey memory key, ArtCoinsTokenV2 token)
    {
        Launch memory l = _defaults(bountyEoa);
        l.taxMode = mode;
        l.baseline = baseline;
        (key, token) = _launch(l);
    }

    function _router(PoolKey memory key, address coin) internal returns (BurnRouterV2 r) {
        r = new BurnRouterV2(address(this), POOL_MANAGER, address(escrow));
        r.initialize(coin, key);
    }

    function _fund(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        require(ok, "fund");
    }

    function _swapper(PoolKey memory key, address coin, address end, uint256 step)
        internal
        returns (FeeAutoSwapperV2 s)
    {
        s = new FeeAutoSwapperV2(
            FeeAutoSwapperV2.Config({
                owner: address(this),
                poolManager: POOL_MANAGER,
                feeEscrow: address(escrow),
                hook: address(hook),
                poolFee: key.fee,
                tickSpacing: key.tickSpacing,
                endRecipient: end,
                artCoin: coin,
                maxSlippageBps: 500,
                minBlocksBetweenConverts: 1,
                maxStepIn: step
            })
        );
        escrow.addDepositor(address(s), false);
    }

    function _burnSelector(BurnRouterV2 r) internal returns (bool ok, bytes4 sel) {
        try r.processBurn(0) {
            ok = true;
        } catch (bytes memory err) {
            sel = bytes4(err);
        }
    }

    // ── V2B-01: burn router floor and reward count the refunded skim ──────

    /// REGRESSION (fixed by D40 and D50, was V2B-01 and V2B-03).
    ///
    /// original attack: default settings, 111 style pool (6% baseline skim,
    /// 0.5% lp fee), 1000 eth full range. a 10 eth budget burns; a 50 eth
    /// budget (5% of the pool's eth) could never burn: the impact limit partial
    /// filled, the hook charged skim on the whole requested input and refunded
    /// the unfilled share later, but `_finish` checked the floor against `ethIn`
    /// including that refundable skim. the balance only grows, so burns stopped
    /// for good, a griefer's donation bricked a working router, and the keeper
    /// reward was sized on the refundable skim.
    ///
    /// now: `ethIn` and the reward exclude the refunded skim, each burn is capped
    /// at `maxBurnPerCall`, so a 50 eth balance drains over blocks and a
    /// donation cannot brick the router. eth stays unrescuable (by design).
    function test_V2B01_burnRouter_bigBudgetNeverBurns_defaultSettings() public onlyFork {
        (PoolKey memory key, ArtCoinsTokenV2 token) = _launchWith(Constants.TAX_MODE_NONE, BASELINE);

        BurnRouterV2 small = _router(key, address(token));
        _fund(address(small), 10 ether);
        uint256 snap = vm.snapshotState();
        uint256 k0 = keeper.balance;
        vm.prank(keeper);
        (uint256 ethIn, uint256 burned) = small.processBurn(0);
        assertGt(burned, 0, "10 eth budget burns");
        uint256 refund = escrow.balances(address(small), address(0));
        // reward is sized on the consumed eth only, not on any refunded skim
        assertEq(keeper.balance - k0, small.rewardFor(ethIn), "reward on consumed only");
        assertLe(ethIn, small.maxBurnPerCall(), "capped per burn");
        emit log_named_uint("10 eth: ethIn net of refunded skim", ethIn);
        emit log_named_uint("10 eth: skim still owed in escrow", refund);
        vm.revertToState(snap);

        // same pool: a 50 eth balance burns every block and drains.
        BurnRouterV2 big = _router(key, address(token));
        _fund(address(big), 50 ether);
        uint256 b0 = block.number;
        for (uint256 i; i < 3; ++i) {
            vm.roll(b0 + i + 1);
            uint256 supply0 = token.totalSupply();
            (bool ok, bytes4 sel) = _burnSelector(big);
            assertTrue(ok, "50 eth budget burns every block");
            assertEq(sel, bytes4(0));
            assertLt(token.totalSupply(), supply0, "coin burned");
        }
        assertLt(address(big).balance, 50 ether, "balance drains over blocks");

        // a donation no longer bricks a working router.
        vm.roll(b0 + 10);
        BurnRouterV2 victim = _router(key, address(token));
        _fund(address(victim), 5 ether);
        vm.deal(griefer, 45 ether);
        vm.prank(griefer);
        _fund(address(victim), 45 ether);
        (bool ok2, bytes4 sel2) = _burnSelector(victim);
        assertTrue(ok2, "donation does not brick the router");
        assertEq(sel2, bytes4(0));

        // eth is still not rescuable.
        vm.expectRevert(abi.encodeWithSelector(IBurnRouterV2.CannotRescue.selector, address(0)));
        victim.rescue(address(0), address(this), 1);
    }

    /// REGRESSION (fixed by D40, was V2B-01).
    ///
    /// original attack: owner levers at their bounds (impact 300 bps, floor
    /// 50%) did not save a 300 eth balance on the same 1000 eth pool, it never
    /// burned. now it burns at the default settings and at the owner limits.
    function test_V2B01_burnRouter_bricked_evenAtOwnerLimits() public onlyFork {
        (PoolKey memory key, ArtCoinsTokenV2 token) = _launchWith(Constants.TAX_MODE_NONE, BASELINE);
        BurnRouterV2 r = _router(key, address(token));
        _fund(address(r), 300 ether);
        (bool ok,) = _burnSelector(r);
        assertTrue(ok, "300 eth burns at the default settings");

        vm.roll(block.number + 1);
        r.setMaxImpactBps(Constants.BURN_IMPACT_MAX);
        r.setSpotFloorBps(Constants.SPOT_FLOOR_MIN_BPS);
        (bool ok2, bytes4 sel2) = _burnSelector(r);
        assertTrue(ok2, "300 eth burns at the owner limits");
        assertEq(sel2, bytes4(0));
    }

    // ── V2B-02: swapper sandwich on a low fee v2 pool ─────────────────────

    /// REGRESSION (fixed by D39, was V2B-02).
    ///
    /// original attack: v2 pool with baseline skim 0 and lp fee 0.5% (both
    /// allowed by the hook). the keeper sold coin, called convert(0), bought the
    /// coin back, all in one tx. the swapper's price limit and spot floor were
    /// both relative to the manipulated spot, so they passed and the attacker
    /// kept the difference (the recipient lost over 25% of the step).
    ///
    /// now: `convert` has an impact cap (`maxImpactBps`, default 100) so it only
    /// sells the coin that fits within the cap of the moved spot. the attacker's
    /// gain is bounded by the cap plus fees and is negative at the default cap.
    function test_V2B02_swapper_sandwich_profitable_lowFeePool() public onlyFork {
        (PoolKey memory key, ArtCoinsTokenV2 token) = _launchWith(Constants.TAX_MODE_NONE, 0);
        V2BSink end = new V2BSink();
        FeeAutoSwapperV2 s = _swapper(key, address(token), address(end), 20e18);
        token.transfer(address(s), 20e18);
        vm.roll(block.number + 1);

        uint256 snap = vm.snapshotState();
        vm.prank(keeper);
        s.convert(0);
        uint256 fairOut = address(end).balance + keeper.balance;
        uint256 fairIn = 20e18 - token.balanceOf(address(s));
        vm.revertToState(snap);

        uint256 eth0 = address(this).balance;
        uint256 coin0 = token.balanceOf(address(this));
        _swap(key, false, -200e18, 0, ""); // push the coin price down
        s.convert(0); // this contract is the keeper
        _swap(key, true, 200e18, 0, ""); // buy exactly the 200 coin back
        assertEq(token.balanceOf(address(this)), coin0, "attacker coin flat");

        uint256 coinIn = 20e18 - token.balanceOf(address(s));
        uint256 value = coinIn * fairOut / fairIn; // fair eth value of the coin sold
        int256 profit = int256(address(this).balance) - int256(eth0);
        uint256 bound = value
            * (s.maxImpactBps() + 2 * uint256(LP_FEE) / 100 + Constants.KEEPER_REWARD_BPS)
            / Constants.BPS;
        emit log_named_uint("recipient eth, honest convert", fairOut);
        emit log_named_uint("recipient eth, sandwiched", address(end).balance);
        emit log_named_int("attacker eth profit", profit);
        assertLe(profit, int256(bound), "attacker gain bounded by impact cap plus fees");
        assertLe(profit, 0, "not profitable at the default cap");
    }

    // ── claims that hold: HARD mode flows through the real hook ───────────

    function test_holds_hardMode_swapperConvert() public onlyFork {
        (PoolKey memory key, ArtCoinsTokenV2 token) = _launchWith(Constants.TAX_MODE_HARD, BASELINE);
        V2BSink end = new V2BSink();
        FeeAutoSwapperV2 s = _swapper(key, address(token), address(end), 1e18);
        token.transfer(address(s), 1e18);
        vm.prank(keeper);
        uint256 out = s.convert(0);
        assertGt(out, 0);
        assertEq(token.balanceOf(address(s)), 0);
        assertEq(address(s).balance, 0);
        (, uint256 fOut, uint256 fIn) = token.pendingCanonical();
        assertEq(fOut + fIn, 0, "grant fully consumed");
    }

    function test_holds_hardMode_burnRouter() public onlyFork {
        (PoolKey memory key, ArtCoinsTokenV2 token) = _launchWith(Constants.TAX_MODE_HARD, BASELINE);
        BurnRouterV2 r = _router(key, address(token));
        _fund(address(r), 1 ether);
        uint256 supply0 = token.totalSupply();
        vm.prank(keeper);
        (, uint256 burned) = r.processBurn(0);
        assertGt(burned, 0);
        assertEq(token.totalSupply(), supply0 - burned);
    }

    function test_holds_venueMode_burnRouter_untaxed() public onlyFork {
        (PoolKey memory key, ArtCoinsTokenV2 token) =
            _launchWith(Constants.TAX_MODE_VENUE, BASELINE);
        BurnRouterV2 r = _router(key, address(token));
        _fund(address(r), 1 ether);
        uint256 dead0 = token.balanceOf(Constants.DEAD);
        vm.prank(keeper);
        r.processBurn(0);
        assertEq(token.balanceOf(Constants.DEAD), dead0, "no tax on the canonical take");
    }

    function _devBuyCall(
        ArtCoinsUniv4EthDevBuyV2 d,
        PoolKey memory key,
        address token,
        uint256 value,
        address buyer,
        address refundTo
    ) internal {
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c;
        c.extensions = new IArtCoinsFactoryV2.ExtensionConfigV2[](1);
        c.extensions[0] = IArtCoinsFactoryV2.ExtensionConfigV2({
            extension: address(d),
            msgValue: value,
            extensionBps: 0,
            extensionData: abi.encode(buyer, refundTo, uint128(1))
        });
        c.pool.hook = address(hook);
        d.receiveTokens{value: value}(c, key, token, 0, 0);
    }

    /// dev buy before `initializeMevModule` (factory order) on a HARD coin:
    /// the take to the recipient is covered by the hook's out grant.
    function test_holds_hardMode_devBuy() public onlyFork {
        ArtCoinsTokenV2 token = _newToken(Constants.TAX_MODE_HARD, bountyEoa, address(hook));
        PoolKey memory key = hook.initializePool(_params(_defaults(bountyEoa), address(token)));
        _modify(key, FULL_LO, FULL_HI, int256(LIQ), 0);
        ArtCoinsUniv4EthDevBuyV2 d = new ArtCoinsUniv4EthDevBuyV2(address(this), POOL_MANAGER);
        address buyer = makeAddr("v2b-buyer");
        _devBuyCall(d, key, address(token), 1 ether, buyer, makeAddr("v2b-refund"));
        assertGt(token.balanceOf(buyer), 0);
    }

    /// partial fill through the real hook: the over charged skim lands in the
    /// escrow under the dev buy contract and is pulled to the refund recipient
    /// in the same call. refund == value - pool input - fair skim.
    function test_holds_devBuy_partialFill_skimRefundReachesRecipient() public onlyFork {
        ArtCoinsTokenV2 token = _newToken(Constants.TAX_MODE_NONE, bountyEoa, address(hook));
        PoolKey memory key = hook.initializePool(_params(_defaults(bountyEoa), address(token)));
        _modify(key, -600, 0, int256(LIQ), 0); // coin only, about 30 eth deep
        ArtCoinsUniv4EthDevBuyV2 d = new ArtCoinsUniv4EthDevBuyV2(address(this), POOL_MANAGER);
        address refundTo = makeAddr("v2b-refund2");
        address buyer = makeAddr("v2b-buyer2");
        uint256 pmEth0 = POOL_MANAGER.balance;
        _devBuyCall(d, key, address(token), 100 ether, buyer, refundTo);
        uint256 poolIn = POOL_MANAGER.balance - pmEth0;
        assertGt(refundTo.balance, 60 ether, "most eth refunded");
        assertEq(escrow.balances(address(d), address(0)), 0, "no skim left in escrow");
        assertEq(address(d).balance, 0);
        // whatever did not go to the pool or the skim legs came back
        assertLt(100 ether - refundTo.balance - poolIn, 3 ether, "only the fair skim kept");
    }
}
