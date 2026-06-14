// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {ArtCoinsToken} from "../src/ArtCoinsToken.sol";
import {ArtCoinsFactory} from "../src/legacy/ArtCoinsFactory.sol";
import {ArtCoinsFeeLocker} from "../src/legacy/ArtCoinsFeeLocker.sol";
import {ArtCoinsLpLockerMultiple} from "../src/lp-lockers/legacy/ArtCoinsLpLockerMultiple.sol";
import {BurnRouter} from "../src/protocol-fee/BurnRouter.sol";
import {ProtocolFeeController} from "../src/protocol-fee/ProtocolFeeController.sol";

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

/// @notice Sepolia smoke test exercising the full fee → LAYER buy-and-burn path:
///         buy ARTTEST with WETH → locker collects fee → distributes per bps →
///         FeeLocker holds for each recipient → claim into BurnRouter +
///         ProtocolFeeController → processFees splits 60/40 → BurnRouter
///         swap WETH→LAYER → burn.
///
/// Required env vars:
///   PRIVATE_KEY, FACTORY, HOOK, LOCKER, FEE_LOCKER,
///   PROTOCOL_FEE_CONTROLLER, BURN_ROUTER, LAYER_TOKEN, ARTTEST_TOKEN
///   POOL_MANAGER (Sepolia: 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543)
///   BUY_AMOUNT_WEI (e.g. 50000000000000000 = 0.05 ETH)
contract SmokeTestArtTestSepolia is Script {
    address constant SEPOLIA_WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address constant SEPOLIA_POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    int24 constant TICK_SPACING = 200;
    uint24 constant FEE_DYNAMIC = 0x800000;

    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        address factoryAddr = vm.envAddress("FACTORY");
        address hook = vm.envAddress("HOOK");
        address lockerAddr = vm.envAddress("LOCKER");
        address feeLockerAddr = vm.envAddress("FEE_LOCKER");
        address pfcAddr = vm.envAddress("PROTOCOL_FEE_CONTROLLER");
        address burnRouterAddr = vm.envAddress("BURN_ROUTER");
        address layer = vm.envAddress("LAYER_TOKEN");
        address arttest = vm.envAddress("ARTTEST_TOKEN");
        uint256 buyAmount = vm.envUint("BUY_AMOUNT_WEI");

        ArtCoinsToken layerTok = ArtCoinsToken(layer);
        ArtCoinsToken artTok = ArtCoinsToken(arttest);

        console2.log("=== Sepolia smoke test: ARTTEST buy -> LAYER burn ===");
        console2.log("Buyer:                 ", me);
        console2.log("Buy amount (wei WETH): ", buyAmount);
        console2.log("");

        uint256 layerSupplyBefore = layerTok.totalSupply();
        console2.log("LAYER totalSupply (before): ", layerSupplyBefore);

        vm.startBroadcast(pk);

        // 1. Deploy a fresh PoolSwapTest helper (Sepolia v4 has no canonical one).
        PoolSwapTest swapTest = new PoolSwapTest(IPoolManager(SEPOLIA_POOL_MANAGER));
        console2.log("PoolSwapTest helper:        ", address(swapTest));

        // 2. Wrap ETH and approve.
        IWETH9(SEPOLIA_WETH).deposit{value: buyAmount}();
        IWETH9(SEPOLIA_WETH).approve(address(swapTest), buyAmount);
        console2.log("Wrapped + approved %s wei WETH", buyAmount);

        // 3. Build ARTTEST/WETH pool key (canonical sort).
        PoolKey memory artKey = _buildKey(arttest, SEPOLIA_WETH, hook);
        bool zeroForOne = Currency.unwrap(artKey.currency0) == SEPOLIA_WETH;
        // amountSpecified < 0 = exact input.
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(buyAmount),
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });
        PoolSwapTest.TestSettings memory ts =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        swapTest.swap(artKey, swapParams, ts, "");
        console2.log("Buy executed.");
        console2.log("ARTTEST received:            ", artTok.balanceOf(me));

        // 4. Collect LP fees into FeeLocker keyed by recipient.
        ArtCoinsLpLockerMultiple(lockerAddr).collectRewards(arttest);
        console2.log("Locker.collectRewards(ARTTEST) done.");

        // 5. Claim WETH for project-burn slot (BurnRouter) and protocol slot (PFC).
        uint256 burnRouterClaimable =
            ArtCoinsFeeLocker(feeLockerAddr).availableFees(burnRouterAddr, SEPOLIA_WETH);
        uint256 pfcClaimable = ArtCoinsFeeLocker(feeLockerAddr).availableFees(pfcAddr, SEPOLIA_WETH);
        console2.log("FeeLocker WETH claimable for BurnRouter: ", burnRouterClaimable);
        console2.log("FeeLocker WETH claimable for PFC:        ", pfcClaimable);

        if (burnRouterClaimable > 0) {
            ArtCoinsFeeLocker(feeLockerAddr).claim(burnRouterAddr, SEPOLIA_WETH);
        }
        if (pfcClaimable > 0) {
            ArtCoinsFeeLocker(feeLockerAddr).claim(pfcAddr, SEPOLIA_WETH);
        }

        // 6. Run PFC split (60% treasury / 40% BurnRouter / 0% rewards).
        if (pfcClaimable > 0) {
            ProtocolFeeController(payable(pfcAddr)).processFees(SEPOLIA_WETH);
            console2.log("PFC.processFees(WETH) done.");
        }

        // 7. Status + burn.
        (uint256 layerHeld, uint256 wethHeld, bool ready) =
            BurnRouter(payable(burnRouterAddr)).status();
        console2.log("BurnRouter LAYER held: ", layerHeld);
        console2.log("BurnRouter WETH held:  ", wethHeld);
        console2.log("BurnRouter ready:      ", ready);

        uint256 minLayerOut =
            BurnRouter(payable(burnRouterAddr)).requiredMinLayerOutForCurrentWethBalance();
        if (ready && minLayerOut > 0) {
            (uint256 wethIn, uint256 layerBurned) =
                BurnRouter(payable(burnRouterAddr)).processBurnWeth(minLayerOut);
            console2.log("BurnRouter.processBurnWeth() WETH spent: ", wethIn);
            console2.log("BurnRouter.processBurnWeth() LAYER burned: ", layerBurned);
        } else if (ready) {
            console2.log("BurnRouter floor unset; skipping processBurnWeth.");
        } else {
            console2.log("BurnRouter not ready (WETH below threshold). Increase BUY_AMOUNT_WEI.");
        }

        vm.stopBroadcast();

        // 8. Final assertion.
        uint256 layerSupplyAfter = layerTok.totalSupply();
        console2.log("LAYER totalSupply (after):  ", layerSupplyAfter);
        console2.log("LAYER burned this run:      ", layerSupplyBefore - layerSupplyAfter);
    }

    function _buildKey(address coin, address weth, address hook)
        internal
        pure
        returns (PoolKey memory)
    {
        (address c0, address c1) = coin < weth ? (coin, weth) : (weth, coin);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: FEE_DYNAMIC,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hook)
        });
    }
}
