// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// independent review of src/v2/hooks/ArtCoinsHookV2.sol. state level proofs
// only (no hostile recipient contracts). see docs/v2/review/v2-review-hook.md.
// each test body is one tx, so transient grants and budget are observable
// after the unlock closes (same approach as test/v2/HookV2.fork.t.sol).

import {HookV2ForkBase} from "../../mocks/HookV2ForkBase.sol";
import {HV2AddRemoveRouter} from "../../mocks/HookV2Mocks.sol";

import {Constants} from "../../../../src/Constants.sol";
import {ArtCoinsTokenV2} from "../../../../src/v2/ArtCoinsTokenV2.sol";

import {console2} from "forge-std/console2.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IErc20Min {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

abstract contract RvPriorTxBase is HookV2ForkBase {
    PoolKey internal key;
    ArtCoinsTokenV2 internal token;
    HV2AddRemoveRouter internal router;
    bytes32 internal constant SALT = bytes32(uint256(9));
    uint256 internal constant POS_LIQ = 20e18;

    function _mode() internal pure virtual returns (uint8);

    function setUp() public virtual override {
        super.setUp();
        if (!onFork) return;
        Launch memory l = _defaults(bountyEoa);
        l.taxMode = _mode();
        (key, token) = _launch(l);
        router = new HV2AddRemoveRouter(pm);
        vm.deal(address(router), 200 ether);
        token.transfer(address(router), 200e18);
        router.run(key, -2000, 2000, POS_LIQ, SALT, 2); // prior tx position
    }
}

/// V2H-02, HARD half: the b1 marker suppresses the remove side grant, so the
/// add side IN grant survives the unlock (D34 netting never sees the remove).
contract RvHardNettingTest is RvPriorTxBase {
    function _mode() internal pure override returns (uint8) {
        return Constants.TAX_MODE_HARD;
    }

    function test_V2H02_hard_addThenRemoveSameTx_leavesInGrant() public onlyFork {
        (, uint256 o0, uint256 i0) = token.pendingCanonical();
        assertEq(o0 + i0, 0);
        // fresh position, add then remove in one unlock, net coin delta zero
        router.run(key, -2000, 2000, 50e18, bytes32(uint256(77)), 0);
        (, uint256 o1, uint256 i1) = token.pendingCanonical();
        assertEq(o1, 0, "no out grant (the author's test checks only this)");
        assertGt(i1, 1e18, "BUG: IN grant equal to the position principal survives, nothing settled it");
        console2.log("leftover HARD inflow grant (coin wei):", i1);
    }

    /// same leak on a prior tx position: increase then decrease by the same
    /// liquidity in one unlock (marker set by the increase) leaves the IN grant.
    function test_V2H02_hard_increaseThenDecreasePrior_leavesInGrant() public onlyFork {
        router.run(key, -2000, 2000, POS_LIQ, SALT, 0);
        (, uint256 o1, uint256 i1) = token.pendingCanonical();
        assertEq(o1, 0);
        assertGt(i1, 0, "BUG: IN grant survives");
    }
}

/// claim check, VENUE: after the D34 wiring in the working tree the hook
/// reports canonical inflows in VENUE too, so these now hold (they failed
/// against commit 590049a, where VENUE inflows were never reported).
contract RvVenueNettingTest is RvPriorTxBase {
    function _mode() internal pure override returns (uint8) {
        return Constants.TAX_MODE_VENUE;
    }

    function test_hold_venue_removeThenReAdd_noNetBudget() public onlyFork {
        (uint256 b0,,) = token.pendingCanonical();
        router.run(key, -2000, 2000, POS_LIQ, SALT, 1); // remove then re add
        (uint256 b1,,) = token.pendingCanonical();
        assertEq(b1, b0, "re add cancels the removal's budget");
    }

    function test_hold_venue_claimsBuyThenSell_cancelsBudget() public onlyFork {
        swapRouter.swap{value: 1 ether}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -1 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}),
            ""
        );
        (uint256 b3,,) = token.pendingCanonical();
        assertGt(b3, 0.5e18, "claims buy leaves budget");
        _swap(key, false, -0.5e18, 0, "");
        (uint256 b4,,) = token.pendingCanonical();
        assertEq(b4, b3 - 0.5e18, "canonical sell cancels budget");
    }
}

/// gas: v2 swap cost vs the live v1 skim hook (coin 111 pool), PoolSwapTest
/// router on both, warm pools, small amounts (no tick crossing).
contract RvGasTest is HookV2ForkBase {
    address internal constant V1_HOOK = 0x636c050296B5Cc528D8785169Bf8923716FCa9cc;
    address internal constant COIN_111 = 0x61C9d89fe1212F6b55fF888816A151463287B8ae;

    function _gasSwap(PoolKey memory k, bool z, int256 amt) internal returns (uint256 used) {
        uint160 lim = z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        uint256 g0 = gasleft();
        swapRouter.swap{value: z ? uint256(-amt) : 0}(
            k,
            IPoolManager.SwapParams({zeroForOne: z, amountSpecified: amt, sqrtPriceLimitX96: lim}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        used = g0 - gasleft();
    }

    function _v2(uint8 mode, string memory label) internal {
        Launch memory l = _defaults(bountyEoa);
        l.taxMode = mode;
        (PoolKey memory k,) = _launch(l);
        _gasSwap(k, true, -0.05 ether); // warm recipients and pool
        _gasSwap(k, false, -0.02e18);
        uint256 buy = _gasSwap(k, true, -0.01 ether);
        uint256 sell = _gasSwap(k, false, -0.005e18);
        console2.log(label, "buy", buy);
        console2.log(label, "sell", sell);
    }

    function test_gas_v2_vs_v1Live() public onlyFork {
        _v2(Constants.TAX_MODE_NONE, "v2 NONE");
        _v2(Constants.TAX_MODE_VENUE, "v2 VENUE");

        PoolKey memory k1 = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(COIN_111),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 200,
            hooks: IHooks(V1_HOOK)
        });
        IErc20Min(COIN_111).approve(address(swapRouter), type(uint256).max);
        _gasSwap(k1, true, -0.05 ether);
        uint256 bal = IErc20Min(COIN_111).balanceOf(address(this));
        _gasSwap(k1, false, -int256(bal / 4));
        uint256 buy = _gasSwap(k1, true, -0.01 ether);
        uint256 sell = _gasSwap(k1, false, -int256(bal / 8));
        console2.log("v1 live 111 buy", buy);
        console2.log("v1 live 111 sell", sell);
    }
}
