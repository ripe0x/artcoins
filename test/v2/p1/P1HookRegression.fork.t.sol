// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HookV2ForkBase} from "../mocks/HookV2ForkBase.sol";

import {Constants} from "../../../src/Constants.sol";
import {ArtCoinsTokenV2} from "../../../src/v2/ArtCoinsTokenV2.sol";
import {FeeAutoSwapperV2} from "../../../src/v2/FeeAutoSwapperV2.sol";
import {IArtCoinsHookV2} from "../../../src/v2/interfaces/IArtCoinsHookV2.sol";
import {IFeeAutoSwapperV2} from "../../../src/v2/interfaces/IFeeAutoSwapperV2.sol";
import {BurnRouterV2} from "../../../src/v2/protocol-fee/BurnRouterV2.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract P1HookSink {
    receive() external payable {}
}

/// @title  P1HookRegressionForkTest
/// @notice Regressions for review v2-b (V2B-01, V2B-02, V2B-03) against the
///         real `ArtCoinsHookV2` and `ArtCoinsTokenV2` on a mainnet fork, same
///         pool setup as `test/v2/review-v2/b/V2BPeriphery.fork.t.sol`
///         (1000 eth full range, 0.5% lp fee).
/// Run: /tmp/claude-0/forge.sh test --match-path "test/v2/p1/P1HookRegression.fork.t.sol" -vv
contract P1HookRegressionForkTest is HookV2ForkBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address internal keeper = makeAddr("p1-keeper");

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

    // ── V2B-01 / V2B-03: burn router on a skim pool ──────────────────────

    /// @notice 50 eth router on a 6% baseline skim, 0.5% lp fee pool: every
    ///         block burns (v1 of this contract reverted `InsufficientOutput`
    ///         forever), at most `maxBurnPerCall` per burn, `ethIn` and the
    ///         keeper reward exclude the skim the hook refunds.
    function test_burnV2_skimPool_50eth_burnsEveryBlock_drains() public onlyFork {
        (PoolKey memory key, ArtCoinsTokenV2 token) = _launchWith(Constants.TAX_MODE_NONE, BASELINE);
        BurnRouterV2 r = _router(key, address(token));
        _fund(address(r), 50 ether);

        uint256 paidTotal;
        uint256 refundSeen;
        uint256 b0 = block.number;
        for (uint256 i; i < 8; ++i) {
            vm.roll(b0 + i + 1); // absolute: via ir may cache block.number
            // the burn first claims any refund left by the previous burn
            uint256 bal0 = address(r).balance + escrow.balances(address(r), address(0));
            uint256 k0 = keeper.balance;
            uint256 supply0 = token.totalSupply();

            vm.prank(keeper);
            (uint256 ethIn, uint256 burned) = r.processBurn(0);

            uint256 reward = keeper.balance - k0;
            uint256 refund = escrow.balances(address(r), address(0));
            uint256 paid = bal0 - address(r).balance - reward;
            assertGt(burned, 0, "burns every block");
            assertEq(token.totalSupply(), supply0 - burned, "burned via token burn");
            // pre D42 hook: refund lands in the escrow (paid includes it);
            // D42 hook: refund settled into the swap delta (paid excludes it)
            assertEq(ethIn + refund, paid, "ethIn excludes the refunded skim");
            assertEq(reward, r.rewardFor(ethIn), "reward on consumed only");
            assertLe(paid, r.maxBurnPerCall(), "capped per burn");
            paidTotal += paid;
            refundSeen += refund;
        }
        emit log_named_uint("eth paid over 8 blocks", paidTotal);
        emit log_named_uint("skim refunded over 8 blocks", refundSeen);
        assertGt(paidTotal, 8 ether, "drains over blocks");
        assertLt(address(r).balance, 50 ether - 8 ether);
    }

    /// @notice Partial fill on the skim pool (cap raised so the impact limit
    ///         binds): the hook refunds the over charged skim (D42: settled
    ///         into this router's PoolManager delta; pre D42: escrow credit).
    ///         The router settles only what it owes (no `CurrencyNotSettled`),
    ///         and `ethIn` and the reward exclude the refund.
    function test_burnV2_skimPool_partialFill_netOfRefund() public onlyFork {
        (PoolKey memory key, ArtCoinsTokenV2 token) = _launchWith(Constants.TAX_MODE_NONE, BASELINE);
        BurnRouterV2 r = _router(key, address(token));
        r.setMaxBurnPerCall(50 ether);
        _fund(address(r), 50 ether);
        uint256 budget = r.swapBudget();

        vm.prank(keeper);
        (uint256 ethIn, uint256 burned) = r.processBurn(0);
        uint256 reward = keeper.balance;
        uint256 refund = escrow.balances(address(r), address(0));
        uint256 paid = 50 ether - address(r).balance - reward;
        emit log_named_uint("budget offered", budget);
        emit log_named_uint("eth paid", paid);
        emit log_named_uint("escrow refund", refund);
        assertGt(burned, 0);
        assertLt(paid, budget / 2, "partial fill, refund not paid");
        assertEq(ethIn + refund, paid, "ethIn net of any refund");
        assertEq(reward, r.rewardFor(ethIn), "reward on consumed only");
    }

    /// @notice The reviewer's 300 eth case (owner limits) and the default
    ///         settings both burn now.
    function test_burnV2_skimPool_300eth_burns() public onlyFork {
        (PoolKey memory key, ArtCoinsTokenV2 token) = _launchWith(Constants.TAX_MODE_NONE, BASELINE);
        BurnRouterV2 r = _router(key, address(token));
        _fund(address(r), 300 ether);
        (uint256 ethIn, uint256 burned) = r.processBurn(0);
        assertGt(burned, 0);
        assertLe(ethIn, r.maxBurnPerCall());

        vm.roll(block.number + 1);
        r.setMaxImpactBps(Constants.BURN_IMPACT_MAX);
        r.setSpotFloorBps(Constants.SPOT_FLOOR_MIN_BPS);
        r.setMaxBurnPerCall(r.MAX_BURN_PER_CALL_MAX());
        (, burned) = r.processBurn(0);
        assertGt(burned, 0, "owner limits burn too");
    }

    // ── V2B-02: swapper sandwich ─────────────────────────────────────────

    /// @notice Reviewer's scenario (baseline skim 0, lp fee 0.5%, step 20 coin,
    ///         slippage 500): the caller sells 200 coin, converts, buys the 200
    ///         back. With the D39 impact cap the swapper only sells the coin
    ///         that fits within `maxImpactBps` of the moved spot, so the
    ///         attacker's gain is bounded by the cap plus fees on the consumed
    ///         value; before D39 it netted +4.13 eth on a 20 coin step.
    function test_swapperV2_sandwich_boundedByImpactCap() public onlyFork {
        (PoolKey memory key, ArtCoinsTokenV2 token) = _launchWith(Constants.TAX_MODE_NONE, 0);
        P1HookSink end = new P1HookSink();
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
        _swap(key, true, 200e18, 0, ""); // buy the 200 coin back
        assertEq(token.balanceOf(address(this)), coin0, "attacker coin flat");

        uint256 coinIn = 20e18 - token.balanceOf(address(s));
        // fair value of the coin the swapper sold in the sandwiched call
        uint256 value = coinIn * fairOut / fairIn;
        int256 profit = int256(address(this).balance) - int256(eth0);
        uint256 bound = value
            * (s.maxImpactBps() + 2 * uint256(LP_FEE) / 100 + Constants.KEEPER_REWARD_BPS)
            / Constants.BPS;
        emit log_named_uint("honest convert: coin in", fairIn);
        emit log_named_uint("honest convert: eth out", fairOut);
        emit log_named_uint("sandwiched: coin in", coinIn);
        emit log_named_uint("sandwiched: recipient eth", address(end).balance);
        emit log_named_int("attacker eth profit", profit);
        emit log_named_uint("bound (impact + 2 lp fee + reward) on consumed value", bound);
        assertLe(profit, int256(bound), "attacker gain bounded by impact cap plus fees");
        // at the default 100 bps cap on a 0.5% lp fee pool the round trip
        // costs the attacker more than it extracts
        assertLe(profit, 0, "not profitable at the default cap");
    }

    // ── D50: fee aware floor ─────────────────────────────────────────────

    /// @notice Reviewer's `test_holds_hardMode_swapperConvert` scenario (HARD
    ///         coin, 6% baseline skim, 0.5% lp fee): converts at the default
    ///         95% floor, because the floor nets out the pool's known fees.
    function test_swapperV2_feeAwareFloor_6pctSkimPool_convertsAtDefault() public onlyFork {
        (PoolKey memory key, ArtCoinsTokenV2 token) = _launchWith(Constants.TAX_MODE_HARD, BASELINE);
        P1HookSink end = new P1HookSink();
        FeeAutoSwapperV2 s = _swapper(key, address(token), address(end), 1e18);
        assertEq(s.poolBaselineSkimBps(), BASELINE, "skim read from the hook");
        assertEq(s.poolLpFee(), LP_FEE, "lp fee read from the hook");
        assertEq(s.spotFloorBps(), 9500, "default floor");
        token.transfer(address(s), 1e18);
        uint256 floor = s.floorFor(1e18);
        vm.prank(keeper);
        uint256 out = s.convert(0);
        emit log_named_uint("out", out);
        emit log_named_uint("fee aware floor", floor);
        assertGe(out, floor);
        assertEq(token.balanceOf(address(s)), 0);
        assertEq(address(s).balance, 0);
    }

    function _swapperBelieving(PoolKey memory key, ArtCoinsTokenV2 token, uint24 believedSkim)
        internal
        returns (FeeAutoSwapperV2 s)
    {
        IArtCoinsHookV2.SkimConfig memory cfg = hook.skimConfig(key.toId());
        cfg.baselineSkimBps = believedSkim;
        vm.mockCall(
            address(hook),
            abi.encodeWithSelector(IArtCoinsHookV2.skimConfig.selector, key.toId()),
            abi.encode(cfg)
        );
        s = _swapper(key, address(token), address(new P1HookSink()), 1e18);
        vm.clearMockedCalls();
        assertEq(s.poolBaselineSkimBps(), believedSkim);
        token.transfer(address(s), 1e18);
    }

    /// @notice Charges beyond the pool's known fees (modelled by a swapper
    ///         that believes a lower baseline than the hook's real 9%, e.g. a
    ///         skim above baseline). The floor is at most 95%
    ///         (`SPOT_FLOOR_MAX_BPS`) of the fee net spot, so it tolerates
    ///         about 5% minus impact: 3% beyond the known fees converts, 6%
    ///         reverts. A same tx sandwich moves the spot the floor reads, so
    ///         no spot floor catches it; the D39 impact cap bounds it instead
    ///         (`test_swapperV2_sandwich_boundedByImpactCap`).
    function test_swapperV2_feeAwareFloor_chargesBeyondKnownFees() public onlyFork {
        (PoolKey memory key, ArtCoinsTokenV2 token) = _launchWith(Constants.TAX_MODE_NONE, 9000);
        assertEq(hook.skimConfig(key.toId()).baselineSkimBps, 9000);
        FeeAutoSwapperV2 three = _swapperBelieving(key, token, 6000);
        FeeAutoSwapperV2 six = _swapperBelieving(key, token, 3000);
        vm.roll(block.number + 1);

        assertGt(three.convert(0), 0, "3% beyond known fees: within the 95% tolerance");
        vm.expectPartialRevert(IFeeAutoSwapperV2.MinOutBelowFloor.selector);
        six.convert(0);

        // anyone resyncs to the hook's real 9%; the floor follows
        six.syncPoolFees();
        assertEq(six.poolBaselineSkimBps(), 9000);
        assertGt(six.convert(0), 0, "converts once the known fees are right");
    }

    /// @notice Router side: fees stored at initialize, floor view nets them out.
    function test_burnV2_feeAwareFloor_storedAndUsed() public onlyFork {
        (PoolKey memory key, ArtCoinsTokenV2 token) = _launchWith(Constants.TAX_MODE_NONE, BASELINE);
        BurnRouterV2 r = _router(key, address(token));
        assertEq(r.poolBaselineSkimBps(), BASELINE);
        assertEq(r.poolLpFee(), LP_FEE);
        (uint160 p,,,) = pm.getSlot0(key.toId());
        uint256 raw = FullMath.mulDiv(FullMath.mulDiv(1 ether, p, 1 << 96), p, 1 << 96);
        uint256 netPpm = 1e6 - uint256(BASELINE) * 10 - LP_FEE;
        assertEq(r.floorFor(1 ether), FullMath.mulDiv(raw, netPpm * 8000, 1e6 * 1e4));
        r.setSpotFloorBps(9500);
        _fund(address(r), 1 ether);
        (, uint256 burned) = r.processBurn(0);
        assertGt(burned, 0, "burns at 95% of the fee net spot");
    }
}
