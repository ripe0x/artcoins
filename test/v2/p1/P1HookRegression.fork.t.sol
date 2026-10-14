// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HookV2ForkBase} from "../mocks/HookV2ForkBase.sol";

import {Constants} from "../../../src/Constants.sol";
import {ArtCoinsTokenV2} from "../../../src/v2/ArtCoinsTokenV2.sol";
import {FeeAutoSwapperV2} from "../../../src/v2/FeeAutoSwapperV2.sol";
import {IArtCoinsHookV2} from "../../../src/v2/interfaces/IArtCoinsHookV2.sol";
import {IFeeAutoSwapperV2} from "../../../src/v2/interfaces/IFeeAutoSwapperV2.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract P1HookSink {
    receive() external payable {}
}

/// @title  P1HookRegressionForkTest
/// @notice Regressions for review v2-b (V2B-02) against the
///         real `ArtCoinsHookV2` and `ArtCoinsTokenV2` on a mainnet fork, same
///         pool setup as `test/v2/review-v2/b/V2BPeriphery.fork.t.sol`
///         (1000 eth full range, 0.5% lp fee).
/// Run: /tmp/claude-0/forge.sh test --match-path "test/v2/p1/P1HookRegression.fork.t.sol" -vv
contract P1HookRegressionForkTest is HookV2ForkBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address internal keeper = makeAddr("p1-keeper");

    function _launchWith(bool restricted, uint24 baseline)
        internal
        returns (PoolKey memory key, ArtCoinsTokenV2 token)
    {
        Launch memory l = _defaults(bountyEoa);
        l.restricted = restricted;
        l.baseline = baseline;
        (key, token) = _launch(l);
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
                coin: coin,
                maxSlippageBps: 500,
                minBlocksBetweenConverts: 1,
                maxStepIn: step
            })
        );
        escrow.addDepositor(address(s), false);
    }

    // ── V2B-02: swapper sandwich ─────────────────────────────────────────

    /// @notice Reviewer's scenario (baseline skim 0, lp fee 0.5%, step 20 coin,
    ///         slippage 500): the caller sells 200 coin, converts, buys the 200
    ///         back. With the D39 impact cap the swapper only sells the coin
    ///         that fits within `maxImpactBps` of the moved spot, so the
    ///         attacker's gain is bounded by the cap plus fees on the consumed
    ///         value; before D39 it netted +4.13 eth on a 20 coin step.
    function test_swapperV2_sandwich_boundedByImpactCap() public onlyFork {
        (PoolKey memory key, ArtCoinsTokenV2 token) = _launchWith(false, 0);
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
        (PoolKey memory key, ArtCoinsTokenV2 token) = _launchWith(true, BASELINE);
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
        (PoolKey memory key, ArtCoinsTokenV2 token) = _launchWith(false, 900);
        assertEq(hook.skimConfig(key.toId()).baselineSkimBps, 900);
        FeeAutoSwapperV2 three = _swapperBelieving(key, token, 600);
        FeeAutoSwapperV2 six = _swapperBelieving(key, token, 300);
        vm.roll(block.number + 1);

        assertGt(three.convert(0), 0, "3% beyond known fees: within the 95% tolerance");
        vm.expectPartialRevert(IFeeAutoSwapperV2.MinOutBelowFloor.selector);
        six.convert(0);

        // anyone resyncs to the hook's real 9%; the floor follows
        six.syncPoolFees();
        assertEq(six.poolBaselineSkimBps(), 900);
        assertGt(six.convert(0), 0, "converts once the known fees are right");
    }
}
