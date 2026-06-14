// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Script, console2} from "forge-std/Script.sol";

interface IWETH9 {
    function deposit() external payable;
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IProtocolFeeController {
    function processFees(address token) external;
}

interface IBurnRouter {
    function processBurnWeth(uint256 minLayerOut)
        external
        returns (uint256 wethIn, uint256 layerBurned);
    function processBurnLayer() external returns (uint256 burned);
    function requiredMinLayerOutForCurrentWethBalance() external view returns (uint256);
}

/// @notice End-to-end fee-flow trace for a non-LAYER token deployed via the
///         factory. Buys TEST, sells TEST, then walks the protocol-fee path
///         all the way to LAYER burns.
contract TraceTestTokenFees is Script {
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant LAYER = 0xb7287e4A5b605aB92A8589C62af8A4ebD347E6c9;
    address constant PFC = 0x5fDc39756A64A84518ef00CB6a0ED46971e00A60;
    address constant BURN_ROUTER = 0x2eDBdF011768d8cd4Ef537658b41440900C52000;
    address constant HOOK = 0xA5eA9904F2cD572c638a1eF81463BDAbEa9D28cc;
    int24 constant TICK_SPACING = 200;
    uint24 constant DYNAMIC_FEE = 0x800000;

    function run() public {
        address token = vm.envAddress("TEST_TOKEN");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address trader = vm.addr(pk);

        console2.log("=== Trace fee flow on TEST token ===");
        console2.log("Token:    %s", token);
        console2.log("Trader:   %s", trader);
        console2.log("");

        // Build the canonical pool key (TEST sorted vs WETH).
        PoolKey memory key = _buildKey(token);
        console2.log("Pool currency0: %s", Currency.unwrap(key.currency0));
        console2.log("Pool currency1: %s", Currency.unwrap(key.currency1));
        console2.log("");

        _logSnapshot("T0 (clean)", token);

        vm.startBroadcast(pk);

        // PoolSwapTest is a v4-core helper that wraps swap() so we can trade
        // without setting up a Universal Router calldata blob.
        PoolSwapTest swapper = new PoolSwapTest(IPoolManager(POOL_MANAGER));

        // Wrap 1 ETH so we can fund swaps with WETH.
        IWETH9(WETH).deposit{value: 1 ether}();
        IWETH9(WETH).approve(address(swapper), type(uint256).max);
        IERC20(token).approve(address(swapper), type(uint256).max);

        // BUY: zeroForOne depends on which currency WETH is.
        // TEST is at 0x7344… and WETH is at 0xC02a… — TEST < WETH, so TEST=currency0, WETH=currency1.
        // Buying TEST means swapping WETH -> TEST = currency1 -> currency0 = !zeroForOne (false).
        bool wethIsCurrency0 = (Currency.unwrap(key.currency0) == WETH);
        bool buyZeroForOne = wethIsCurrency0; // pay currency0 to receive currency1
        // Inverse: selling TEST means token -> WETH. Token is whichever isn't WETH.
        bool sellZeroForOne = !wethIsCurrency0;

        // ── Buy 1: 0.05 ETH worth of TEST ──
        _doSwap(swapper, key, buyZeroForOne, 0.05 ether, "BUY 0.05 WETH -> TEST");
        // ── Buy 2: another 0.05 ETH ──
        _doSwap(swapper, key, buyZeroForOne, 0.05 ether, "BUY 0.05 WETH -> TEST");
        // ── Buy 3: another 0.05 ETH ──
        _doSwap(swapper, key, buyZeroForOne, 0.05 ether, "BUY 0.05 WETH -> TEST");

        _logSnapshot("After 3 buys", token);

        // ── Sell back ~half of accumulated TEST ──
        uint256 testBal = IERC20(token).balanceOf(trader);
        uint256 sellAmt = testBal / 2;
        _doSwap(swapper, key, sellZeroForOne, sellAmt, "SELL ~half of TEST -> WETH");

        _logSnapshot("After 1 sell", token);

        vm.stopBroadcast();
    }

    function _buildKey(address token) internal pure returns (PoolKey memory key) {
        (address c0, address c1) = token < WETH ? (token, WETH) : (WETH, token);
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: DYNAMIC_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(HOOK)
        });
    }

    function _doSwap(
        PoolSwapTest swapper,
        PoolKey memory key,
        bool zeroForOne,
        uint256 amount,
        string memory label
    ) internal {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: zeroForOne
                ? uint160(4_295_128_740)
                : uint160(1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341)
        });
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        try swapper.swap(key, params, settings, "") {
            console2.log(label);
        } catch (bytes memory err) {
            console2.log(label, "REVERTED");
            console2.logBytes(err);
        }
    }

    function _logSnapshot(string memory label, address token) internal view {
        console2.log("");
        console2.log("--- %s ---", label);
        console2.log("  LAYER totalSupply:   %s", _fmt18(IERC20(LAYER).totalSupply()));
        console2.log("  BurnRouter WETH:     %s", _fmt18(IWETH9(WETH).balanceOf(BURN_ROUTER)));
        console2.log("  BurnRouter TEST:     %s", _fmt18(IERC20(token).balanceOf(BURN_ROUTER)));
        console2.log("  BurnRouter LAYER:    %s", _fmt18(IERC20(LAYER).balanceOf(BURN_ROUTER)));
        console2.log("  PFC WETH:            %s", _fmt18(IWETH9(WETH).balanceOf(PFC)));
        console2.log("  PFC TEST:            %s", _fmt18(IERC20(token).balanceOf(PFC)));
    }

    function _fmt18(uint256 x) internal pure returns (string memory) {
        if (x == 0) return "0";
        return string.concat(_decimal(x), " (raw ", vm.toString(x), ")");
    }

    function _decimal(uint256 x) internal pure returns (string memory) {
        uint256 whole = x / 1e18;
        uint256 frac = (x / 1e12) % 1e6;
        return string.concat(vm.toString(whole), ".", _pad6(frac));
    }

    function _pad6(uint256 n) internal pure returns (string memory) {
        bytes memory s = bytes(vm.toString(n));
        if (s.length >= 6) return string(s);
        bytes memory padded = new bytes(6);
        uint256 pad = 6 - s.length;
        for (uint256 i = 0; i < pad; i++) {
            padded[i] = "0";
        }
        for (uint256 i = 0; i < s.length; i++) {
            padded[pad + i] = s[i];
        }
        return string(padded);
    }
}
