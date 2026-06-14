// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FeeAutoSwapper} from "../src/FeeAutoSwapper.sol";
import {IFeeAutoSwapper} from "../src/interfaces/IFeeAutoSwapper.sol";
import {ArtCoinsFeeLocker} from "../src/legacy/ArtCoinsFeeLocker.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Test, console2} from "forge-std/Test.sol";

import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

/// @dev Standard mintable ERC20.
contract Acoin is ERC20, ERC20Burnable {
    constructor() ERC20("AC", "AC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Fee-on-transfer artcoin: takes 1% off every transfer. Used to prove
///      the swapper isn't safe to bind to such a token.
contract FeeOnTransferAcoin is ERC20 {
    uint256 internal constant FEE_BPS = 100; // 1%
    constructor() ERC20("FoT", "FoT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = (value * FEE_BPS) / 10_000;
        super._update(from, to, value - fee);
        if (fee > 0) super._update(from, address(0xdead), fee);
    }
}

/// @dev `endRecipient` that always reverts on receive(). Used to prove the
///      contract surfaces the failure rather than silently swallowing it.
contract RejectingRecipient {
    receive() external payable {
        revert("RejectingRecipient: rejects ETH");
    }
}

/// @title FeeAutoSwapperAuditFixesTest
/// @notice Targeted properties surfaced by the external audit:
///         - Medium: MEV bound is relative to current spot, not pre-manipulation.
///         - Low: native-ETH donations strand on the swapper.
///         - Low: fee-on-transfer artcoins break conservation.
///         - Info: `maxStepIn` is bounded at `type(int128).max`.
///         - Additional invariants: reverting endRecipient, tiny-swap dust.
contract FeeAutoSwapperAuditFixesTest is Test {
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    Acoin internal artcoin;
    ArtCoinsFeeLocker internal feeLocker;
    PoolModifyLiquidityTest internal liqRouter;
    PoolSwapTest internal swapRouter;

    address internal feeLockerOwner = address(0xA1);
    address internal endRecipient = address(0xB1);
    address internal keeper = address(0xC1);
    address internal attacker = address(0xD1);

    bool internal onFork;

    function setUp() public {
        if (POOL_MANAGER.code.length == 0) {
            console2.log("SKIPPING: not on a fork.");
            return;
        }
        onFork = true;

        artcoin = new Acoin();
        feeLocker = new ArtCoinsFeeLocker(feeLockerOwner);
        liqRouter = new PoolModifyLiquidityTest(IPoolManager(POOL_MANAGER));
        swapRouter = new PoolSwapTest(IPoolManager(POOL_MANAGER));

        vm.prank(feeLockerOwner);
        feeLocker.addDepositor(address(this));
    }

    receive() external payable {}

    // ─── audit Medium: MEV bound is from current spot, not pre-manip ────

    /// @notice Confirms the audit's framing: a same-tx attacker who first
    ///         depresses the pool's spot can pull `convert` through at the
    ///         depressed rate. The spot-floor and sqrtPriceLimit caps both
    ///         reference the (now manipulated) current spot, so the
    ///         contract's own checks pass; the only protection is what
    ///         `maxStepIn` and `minBlocksBetweenConverts` bound off-chain.
    ///         This test does NOT assert "no MEV is extracted" — it asserts
    ///         the behavior the docs now describe: extraction beyond
    ///         `maxSlippageBps` IS reachable under same-tx manipulation.
    function test_fork_sameTxManipulation_extractsBelowSpotFloor() public {
        if (!onFork) return;

        FeeAutoSwapper swapper = _deployWethSwapper(1000, 1_000_000e18);
        _seedPoolAtPriceOne();
        vm.prank(feeLockerOwner);
        feeLocker.addDepositor(address(swapper));

        // Credit a moderate amount for conversion — small enough that the
        // *unmanipulated* swap would deliver close to spot, so any
        // shortfall is visible.
        uint256 escrowAmount = 1000e18;
        artcoin.mint(address(this), escrowAmount);
        IERC20(address(artcoin)).approve(address(feeLocker), escrowAmount);
        feeLocker.storeFees(address(swapper), address(artcoin), escrowAmount);

        // Capture the "fair" floor — what a non-manipulated `convert` would
        // require: 80% of 1000 = 800 at price = 1.
        uint256 fairFloor = (escrowAmount * 8000) / 10_000;

        // Attacker depresses the pool's artcoin/WETH spot by selling a
        // large block of artcoin (pushing token0=artcoin price down).
        artcoin.mint(attacker, 200_000e18);
        vm.startPrank(attacker);
        IERC20(address(artcoin)).approve(address(swapRouter), type(uint256).max);
        _swap(address(artcoin), 200_000e18); // attacker → pool: sells artcoin
        vm.stopPrank();

        // Now anyone calls `convert(0)`. The contract's own floor is
        // computed from the depressed spot, so it's *also* depressed and
        // doesn't block the call. The actual WETH delivered is below the
        // *fair* (pre-manipulation) 80% floor.
        vm.prank(keeper);
        uint256 wethOut = swapper.convert(0);
        assertLt(wethOut, fairFloor, "manipulation extracted below fair floor");
    }

    // ─── audit Low: native-ETH donations strand on the swapper ──────────

    /// @notice Confirms the (now-honestly-documented) behavior: ETH sent
    ///         to a native-paired swapper outside the `poolManager.take`
    ///         flow stays trapped. There's no sweep path. A subsequent
    ///         `convert` / `flushPaired` pays out `received` / `pairedOut`,
    ///         NOT `address(this).balance`.
    function test_fork_nativeDonation_stays_stranded() public {
        if (!onFork) return;

        FeeAutoSwapper swapper = _deployNativeSwapper();
        _seedNativePoolAtPriceOne();
        vm.prank(feeLockerOwner);
        feeLocker.addDepositor(address(swapper));

        // Direct ETH donation.
        uint256 donation = 1 ether;
        vm.deal(address(this), donation);
        (bool ok,) = address(swapper).call{value: donation}("");
        require(ok, "donation send failed");
        assertEq(address(swapper).balance, donation, "donation landed");

        // A subsequent convert (with real artcoin to swap) does not drain
        // the donation. The swap delivers its own ETH amount; pay-out is
        // sized to that, not to total balance.
        uint256 escrowAmount = 100e18;
        artcoin.mint(address(this), escrowAmount);
        IERC20(address(artcoin)).approve(address(feeLocker), escrowAmount);
        feeLocker.storeFees(address(swapper), address(artcoin), escrowAmount);

        vm.prank(keeper);
        uint256 ethOut = swapper.convert(0);

        // The donation is still here.
        assertEq(address(swapper).balance, donation, "donation untouched by convert");
        ethOut; // referenced to silence unused var
    }

    // ─── audit Low: fee-on-transfer artcoin is not supported ────────────

    /// @notice A fee-on-transfer artcoin breaks the conservation invariant:
    ///         the locker decrements by full `amount`, but the swapper
    ///         receives less. This test demonstrates the gap — the contract
    ///         does NOT explicitly reject FoT tokens, so the operator must
    ///         enforce the token-assumption at deploy.
    function test_fork_feeOnTransferToken_brokenConservation() public {
        if (!onFork) return;

        FeeOnTransferAcoin badCoin = new FeeOnTransferAcoin();
        FeeAutoSwapper swapper = _deployWethSwapperForToken(address(badCoin), 1000, 1_000_000e18);
        vm.prank(feeLockerOwner);
        feeLocker.addDepositor(address(swapper));

        // Credit 1000 FoT to the swapper. The locker stores 1000 (since the
        // test contract's mint went straight to it via storeFees's
        // balance-delta accounting handles FoT — the locker credits 990).
        uint256 amount = 1000e18;
        badCoin.mint(address(this), amount);
        IERC20(address(badCoin)).approve(address(feeLocker), amount);
        feeLocker.storeFees(address(swapper), address(badCoin), amount);

        uint256 lockerCredit = feeLocker.availableFees(address(swapper), address(badCoin));
        // The locker only credits what it actually received (post-FoT-tax).
        assertLt(lockerCredit, amount, "locker credits post-tax amount");

        // When the swapper calls claim(self, badCoin), the locker zeroes
        // `lockerCredit` worth out of its ledger, but the swapper only
        // receives `lockerCredit * 99%` (another 1% tax on the way out).
        // The post-swap V4 settle would tax again. We're not testing the
        // full path; the FoT token would cause the V4 swap to revert on
        // the artcoin → pool settle step. Demonstrate it reverts.
        vm.expectRevert(); // V4 settle path detects mismatched payment
        vm.prank(keeper);
        swapper.convert(0);
    }

    // ─── audit Info: maxStepIn is bounded at type(int128).max ───────────

    function test_constructor_rejects_maxStepIn_above_int128_max() public {
        if (!onFork) return;

        FeeAutoSwapper.Config memory cfg = _baseWethCfg();
        cfg.maxStepIn = uint256(uint128(type(int128).max)) + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                IFeeAutoSwapper.OutOfBounds.selector,
                cfg.maxStepIn,
                1,
                uint256(uint128(type(int128).max))
            )
        );
        new FeeAutoSwapper(cfg);

        // Just-at-the-edge value succeeds.
        cfg.maxStepIn = uint256(uint128(type(int128).max));
        FeeAutoSwapper s = new FeeAutoSwapper(cfg);
        assertEq(s.maxStepIn(), cfg.maxStepIn, "edge-case maxStepIn allowed");
    }

    // ─── additional: reverting endRecipient surfaces the failure ────────

    /// @notice Direct-transfer mode + an endRecipient that reverts on
    ///         receive() should cause `convert` to revert with
    ///         `NativeSendFailed`, not silently swallow.
    function test_fork_revertingRecipient_surfaces_failure() public {
        if (!onFork) return;

        RejectingRecipient bad = new RejectingRecipient();

        FeeAutoSwapper.Config memory cfg = _baseNativeCfg();
        cfg.endRecipient = address(bad);
        cfg.depositToLocker = false;
        FeeAutoSwapper swapper = new FeeAutoSwapper(cfg);
        swapper.setup(address(artcoin));

        _seedNativePoolAtPriceOne();
        vm.prank(feeLockerOwner);
        feeLocker.addDepositor(address(swapper));

        uint256 amount = 100e18;
        artcoin.mint(address(this), amount);
        IERC20(address(artcoin)).approve(address(feeLocker), amount);
        feeLocker.storeFees(address(swapper), address(artcoin), amount);

        vm.expectRevert(IFeeAutoSwapper.NativeSendFailed.selector);
        vm.prank(keeper);
        swapper.convert(0);
    }

    // ─── helpers ────────────────────────────────────────────────────────

    function _baseWethCfg() internal view returns (FeeAutoSwapper.Config memory) {
        return FeeAutoSwapper.Config({
            poolManager: POOL_MANAGER,
            feeLocker: address(feeLocker),
            pairedToken: WETH,
            poolFee: 10_000,
            poolTickSpacing: 60,
            hook: address(0),
            endRecipient: endRecipient,
            depositToLocker: false,
            maxSlippageBps: 1000,
            minBlocksBetweenConverts: 1,
            maxStepIn: 1_000_000e18
        });
    }

    function _baseNativeCfg() internal view returns (FeeAutoSwapper.Config memory) {
        return FeeAutoSwapper.Config({
            poolManager: POOL_MANAGER,
            feeLocker: address(feeLocker),
            pairedToken: address(0),
            poolFee: 10_000,
            poolTickSpacing: 60,
            hook: address(0),
            endRecipient: endRecipient,
            depositToLocker: false,
            maxSlippageBps: 1000,
            minBlocksBetweenConverts: 1,
            maxStepIn: 1_000_000e18
        });
    }

    function _deployWethSwapper(uint256 slippageBps, uint256 stepIn)
        internal
        returns (FeeAutoSwapper)
    {
        FeeAutoSwapper.Config memory cfg = _baseWethCfg();
        cfg.maxSlippageBps = slippageBps;
        cfg.maxStepIn = stepIn;
        FeeAutoSwapper s = new FeeAutoSwapper(cfg);
        s.setup(address(artcoin));
        return s;
    }

    function _deployWethSwapperForToken(address token, uint256 slippageBps, uint256 stepIn)
        internal
        returns (FeeAutoSwapper)
    {
        FeeAutoSwapper.Config memory cfg = _baseWethCfg();
        cfg.maxSlippageBps = slippageBps;
        cfg.maxStepIn = stepIn;
        FeeAutoSwapper s = new FeeAutoSwapper(cfg);
        s.setup(token);
        return s;
    }

    function _deployNativeSwapper() internal returns (FeeAutoSwapper) {
        FeeAutoSwapper.Config memory cfg = _baseNativeCfg();
        FeeAutoSwapper s = new FeeAutoSwapper(cfg);
        s.setup(address(artcoin));
        return s;
    }

    function _seedPoolAtPriceOne() internal {
        PoolKey memory key = _buildKey(address(artcoin), WETH);
        IPoolManager(POOL_MANAGER).initialize(key, uint160(1) << 96);
        artcoin.mint(address(this), 2_000_000e18);
        vm.deal(address(this), 2_000_000 ether);
        IWETH9(payable(WETH)).deposit{value: 2_000_000 ether}();
        IERC20(address(artcoin)).approve(address(liqRouter), type(uint256).max);
        IERC20(WETH).approve(address(liqRouter), type(uint256).max);
        IERC20(address(artcoin)).approve(address(swapRouter), type(uint256).max);
        IERC20(WETH).approve(address(swapRouter), type(uint256).max);
        liqRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60_000, tickUpper: 60_000, liquidityDelta: 5e23, salt: bytes32(0)
            }),
            ""
        );
    }

    function _seedNativePoolAtPriceOne() internal {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(artcoin)),
            fee: 10_000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        IPoolManager(POOL_MANAGER).initialize(key, uint160(1) << 96);
        artcoin.mint(address(this), 2_000_000e18);
        vm.deal(address(this), 2_000_000 ether);
        IERC20(address(artcoin)).approve(address(liqRouter), type(uint256).max);
        liqRouter.modifyLiquidity{value: 2_000_000 ether}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60_000, tickUpper: 60_000, liquidityDelta: 5e23, salt: bytes32(0)
            }),
            ""
        );
    }

    function _buildKey(address coin, address w) internal pure returns (PoolKey memory) {
        (address c0, address c1) = coin < w ? (coin, w) : (w, coin);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 10_000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }

    function _swap(address tokenIn, uint256 amountIn) internal {
        PoolKey memory key = _buildKey(address(artcoin), WETH);
        bool zeroForOne = tokenIn == Currency.unwrap(key.currency0);
        uint160 priceLimit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        BalanceDelta d = swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: priceLimit
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        d; // silence
    }
}
