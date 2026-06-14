// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IWETH9 {
    function deposit() external payable;
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IHookProtocolFee {
    function protocolFeeNumerator() external view returns (uint256);
    function protocolFee() external view returns (uint24);
}

/// @notice Regression test for the Model B bug: with the hook's
///         `protocolFeeNumerator` at 0, the hook MUST NOT take a hook-level
///         skim on top of the pool fee. Trader pays exactly the pool fee.
///
///         Forks Sepolia and does a real swap on the live LAYER pool.
///         The Sepolia hook was patched to numerator=0; if a future change
///         re-enables hook-level fees, this test fails.
///
/// Run:  forge test --match-contract HookProtocolFeeNumeratorZero \
///         --fork-url $SEPOLIA_RPC_URL -vv
contract HookProtocolFeeNumeratorZeroTest is Test {
    address constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address constant FACTORY = 0xaC2C38801485451317D9212d9631B1221A11AD6c;
    address constant HOOK = 0xeD8c1F32CD8cC5691449dFA78Cd81509252B28CC;
    address constant LAYER_TOKEN = 0x6C9C31127738Cf50E1a8d3747C0B1021AeBa4ede;

    int24 constant TICK_SPACING = 200;
    uint24 constant FEE_DYNAMIC = 0x800000;

    PoolSwapTest internal swapRouter;
    PoolKey internal layerKey;
    bool internal _onFork;

    function setUp() public {
        if (POOL_MANAGER.code.length == 0) {
            console2.log("SKIPPING: not on Sepolia fork");
            return;
        }
        _onFork = true;

        (address c0, address c1) = LAYER_TOKEN < WETH ? (LAYER_TOKEN, WETH) : (WETH, LAYER_TOKEN);
        layerKey = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: FEE_DYNAMIC,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(HOOK)
        });
        swapRouter = new PoolSwapTest(IPoolManager(POOL_MANAGER));
    }

    modifier onlyFork() {
        if (!_onFork) return;
        _;
    }

    receive() external payable {}

    /// @dev Hard invariant: artcoins v1 hooks must have zero numerator.
    function test_protocolFeeNumeratorIsZero() public view onlyFork {
        assertEq(
            IHookProtocolFee(HOOK).protocolFeeNumerator(),
            0,
            "Hook protocolFeeNumerator must be 0 in artcoins v1"
        );
    }

    /// @dev With numerator=0, a real swap must NOT increase the hook's
    ///      claim-token balance for either pool currency. Any increase
    ///      means the hook is skimming on top of the pool fee.
    function test_swapDoesNotAccumulateHookClaimTokens() public onlyFork {
        uint256 BUY = 0.01 ether;
        vm.deal(address(this), BUY);
        IWETH9(WETH).deposit{value: BUY}();
        IERC20(WETH).approve(address(swapRouter), BUY);

        uint256 hookWethBefore = IPoolManager(POOL_MANAGER).balanceOf(HOOK, uint256(uint160(WETH)));
        uint256 hookLayerBefore =
            IPoolManager(POOL_MANAGER).balanceOf(HOOK, uint256(uint160(LAYER_TOKEN)));

        bool zeroForOne = LAYER_TOKEN > WETH;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(BUY),
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });
        swapRouter.swap(
            layerKey,
            params,
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 hookWethAfter = IPoolManager(POOL_MANAGER).balanceOf(HOOK, uint256(uint160(WETH)));
        uint256 hookLayerAfter =
            IPoolManager(POOL_MANAGER).balanceOf(HOOK, uint256(uint160(LAYER_TOKEN)));

        // Hook may have FLUSHED prior swap's claim tokens to factory at start
        // of this swap (hookWethAfter could be < hookWethBefore). What matters
        // is that *no new claim tokens are minted to the hook for this swap*.
        // With numerator=0, scaledProtocolFee=0, so the beforeSwap delta
        // doesn't mint anything to the hook.
        // The cleanest invariant: hook's after-balance must not exceed
        // before-balance for either currency — any growth = a skim happened.
        assertLe(
            hookWethAfter,
            hookWethBefore,
            "WETH claim tokens grew on hook -- numerator skim is active"
        );
        assertLe(
            hookLayerAfter,
            hookLayerBefore,
            "LAYER claim tokens grew on hook -- numerator skim is active"
        );

        // Belt-and-suspenders: the per-swap protocolFee state variable should
        // still be zero after the swap (since fee × 0 / 1e6 = 0).
        assertEq(IHookProtocolFee(HOOK).protocolFee(), 0, "protocolFee state nonzero");
    }
}
