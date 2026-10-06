// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {ArtCoinsFeeEscrowV2} from "../../../src/v2/ArtCoinsFeeEscrowV2.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Burnable erc20 standing in for a v2 art coin (the v2 token is
///         owned by another package and may not compile yet).
contract P1Coin is ERC20Burnable {
    constructor() ERC20("p1 coin", "P1") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Second erc20 for rescue tests.
contract P1Stray is ERC20 {
    constructor() ERC20("stray", "STRAY") {
        _mint(msg.sender, 1_000_000e18);
    }
}

/// @notice Rejects every eth transfer.
contract P1Rejector {
    receive() external payable {
        revert("no eth");
    }
}

/// @notice Burns all forwarded gas on receipt.
contract P1GasBurner {
    receive() external payable {
        while (true) {}
    }
}

/// @notice Accepts eth.
contract P1Sink {
    receive() external payable {}
}

/// @title  P1Base
/// @notice Shared setup for package p1 tests: mainnet fork at the harness
///         block (live PoolManager 0x0000…4444c5dc) with a fresh hookless
///         native eth / coin pool. When the rpc is unreachable it falls back to
///         a PoolManager built from `lib/v4-core` (same code), so the tests
///         still run; `forked` says which. `SKIP_FORK_TESTS=true` forces local.
abstract contract P1Base is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant FORK_BLOCK = 26_130_269;
    address internal constant MAINNET_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    string internal constant DEFAULT_RPC = "https://mainnet.gateway.tenderly.co";

    /// @dev 1 eth = 1e6 coin. sqrt(1e6) * 2^96.
    uint160 internal constant SQRT_PRICE_1E6 = 79_228_162_514_264_337_593_543_950_336_000;
    uint24 internal constant POOL_FEE = 10_000;
    int24 internal constant TICK_SPACING = 200;
    /// @dev full range liquidity ~ 100 eth and 1e8 coin.
    int256 internal constant LIQUIDITY = 1e23;

    bool internal forked;
    IPoolManager internal pm;
    PoolModifyLiquidityTest internal lpRouter;
    PoolSwapTest internal swapRouter;
    ArtCoinsFeeEscrowV2 internal escrow;
    P1Coin internal coin;
    PoolKey internal key;

    receive() external payable {}

    function _setUpChain() internal {
        if (!vm.envOr("SKIP_FORK_TESTS", false)) {
            string memory rpc = vm.envOr("MAINNET_RPC_URL", string(DEFAULT_RPC));
            try vm.createSelectFork(rpc, FORK_BLOCK) returns (uint256) {
                forked = true;
            } catch {}
        }
        if (forked) {
            pm = IPoolManager(MAINNET_POOL_MANAGER);
        } else {
            console2.log("p1: rpc unreachable, using a local PoolManager from lib/v4-core");
            pm = IPoolManager(address(new PoolManager(address(this))));
        }
        lpRouter = new PoolModifyLiquidityTest(pm);
        swapRouter = new PoolSwapTest(pm);
        escrow = new ArtCoinsFeeEscrowV2(address(this));
        coin = new P1Coin();

        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(coin)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        pm.initialize(key, SQRT_PRICE_1E6);

        vm.deal(address(this), 10_000 ether);
        coin.mint(address(this), 1e30);
        coin.approve(address(lpRouter), type(uint256).max);
        coin.approve(address(swapRouter), type(uint256).max);
        lpRouter.modifyLiquidity{value: 200 ether}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: LIQUIDITY,
                salt: bytes32(0)
            }),
            ""
        );
    }

    function _spot() internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = pm.getSlot0(key.toId());
    }

    /// @dev Buys coin with `ethIn` eth (moves sqrt price down).
    function _buyCoin(uint256 ethIn) internal {
        swapRouter.swap{value: ethIn}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(ethIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev Sells `coinIn` coin for eth (moves sqrt price up).
    function _sellCoin(uint256 coinIn) internal {
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(coinIn),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev Price ratio new/old in bps from two sqrt prices.
    function _priceMoveBps(uint160 a, uint160 b) internal pure returns (uint256) {
        (uint256 hi, uint256 lo) = a > b ? (uint256(a), uint256(b)) : (uint256(b), uint256(a));
        // (hi/lo)^2 - 1 in bps, computed in 1e18 fixed point
        uint256 r = (hi * 1e18) / lo;
        return ((r * r) / 1e18 - 1e18) * 10_000 / 1e18;
    }
}
