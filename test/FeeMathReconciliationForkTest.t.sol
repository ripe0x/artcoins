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

import {ArtCoinsFeeLocker} from "../src/legacy/ArtCoinsFeeLocker.sol";
import {ArtCoinsLpLockerMultiple} from "../src/lp-lockers/legacy/ArtCoinsLpLockerMultiple.sol";
import {ProtocolFeeController} from "../src/protocol-fee/ProtocolFeeController.sol";

interface IWETH9 {
    function deposit() external payable;
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IArtCoinsHookProtocolFee {
    function protocolFeeNumerator() external view returns (uint256);
    function claimProtocolFees(PoolKey calldata) external;
}

interface IFactoryClaim {
    function claimTeamFees(address token) external;
    function teamFeeRecipient() external view returns (address);
}

/// @notice Reconciliation: do an actual buy on the live Sepolia LAYER pool and
///         measure where every wei ends up. Tests model A vs model B claims
///         about hook protocol fee + locker protocol slot double-counting.
///
///         Model A (LayerFeeMath assumption):
///           1.0% effective fee
///           burn=0.50%, treasury=0.50%
///         Model B (analytical reading of hook code):
///           1.2% effective fee
///           hook takes 0.2% to factory; locker distributes another ~0.998%
///           burn ≈ 0.58%, treasury ≈ 0.62%, double-counted protocol slot
///
/// Run:  forge test --match-contract FeeMathReconciliationForkTest \
///         --fork-url $SEPOLIA_RPC_URL -vv
contract FeeMathReconciliationForkTest is Test {
    // ─── Sepolia state ────────────────────────────────────────────────
    address constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;

    address constant FACTORY = 0xaC2C38801485451317D9212d9631B1221A11AD6c;
    address constant HOOK = 0xeD8c1F32CD8cC5691449dFA78Cd81509252B28CC;
    address constant LOCKER = 0x6BF7693f94f51333E12151AbbaABb49867bF4c9C;
    address constant FEE_LOCKER = 0xa8F7e33F9bac7960AB3a9780C79e3DEd98EdaEd6;
    address constant LAYER_TOKEN = 0x6C9C31127738Cf50E1a8d3747C0B1021AeBa4ede;
    address constant BURN_ROUTER = 0xa02Ba69A5e0856E3101Eb31D3abeEfc0F6fC9BDd;
    address constant PFC = 0xE92e7FbbaADFe83CdD7eac813041c50d33D999E0;
    address constant ARTIST_TREASURY = 0x4fa58fFc00D973fD222d573C256Eb3Cc81A8569c;

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

        // PoolKey for LAYER/WETH on Sepolia (sorted, dynamic fee, hook).
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

    /// @notice Single 0.1 ETH WETH→LAYER buy. Reconcile every wei.
    function test_reconcile_buyWethForLayer() public onlyFork {
        uint256 BUY = 0.1 ether;

        console2.log("");
        console2.log("=== LAYER fee-math reconciliation: 0.1 ETH WETH -> LAYER ===");
        console2.log("Pool fee tier (LAYER artCoinFee/pairedFee): 10_000 ppm = 1%");
        uint256 numerator = IArtCoinsHookProtocolFee(HOOK).protocolFeeNumerator();
        console2.log("Hook protocolFeeNumerator: %s ppm", numerator);

        // 1. Fund a fresh trader with WETH.
        address trader = address(this);
        vm.deal(trader, BUY * 2);
        IWETH9(WETH).deposit{value: BUY}();
        IERC20(WETH).approve(address(swapRouter), BUY);

        // 2. Snapshot all the balances we care about.
        Snap memory s0 = _snap();
        console2.log("\n--- before ---");
        _logSnap(s0);

        // 3. Execute one buy.
        bool zeroForOne = LAYER_TOKEN > WETH; // WETH is currency0 if LAYER>WETH
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

        Snap memory s1 = _snap();
        console2.log("\n--- after swap ---");
        _logSnap(s1);

        // 4. Trigger downstream collections so per-recipient balances settle.
        // a. Locker pulls accrued LP fees into FeeLocker per reward array.
        try ArtCoinsLpLockerMultiple(LOCKER).collectRewards(LAYER_TOKEN) {}
        catch (bytes memory err) {
            console2.log("collectRewards reverted (continuing):");
            console2.logBytes(err);
        }
        // b. Hook protocol-fee path: forces hook to take its claim tokens
        //    and transfer to factory (would otherwise wait for next swap).
        try IArtCoinsHookProtocolFee(HOOK).claimProtocolFees(layerKey) {}
            catch {
            // Falls through if access-controlled or auto-flushed already.
        }
        // c. Factory sweeps claimed token balance to teamFeeRecipient (= PFC).
        try IFactoryClaim(FACTORY).claimTeamFees(WETH) {}
        catch (bytes memory err) {
            console2.log("claimTeamFees reverted (continuing):");
            console2.logBytes(err);
        }
        // d. FeeLocker.claim → push escrowed amounts to BurnRouter / PFC / artist.
        try ArtCoinsFeeLocker(FEE_LOCKER).claim(BURN_ROUTER, WETH) {} catch {}
        try ArtCoinsFeeLocker(FEE_LOCKER).claim(PFC, WETH) {} catch {}
        try ArtCoinsFeeLocker(FEE_LOCKER).claim(ARTIST_TREASURY, WETH) {} catch {}
        // e. PFC splits its WETH 60/40 → treasury + BurnRouter.
        try ProtocolFeeController(payable(PFC)).processFees(WETH) {} catch {}

        Snap memory s2 = _snap();
        console2.log("\n--- after collection chain ---");
        _logSnap(s2);

        // 5. Compute deltas and reconcile.
        console2.log("\n=== reconciliation ===");
        uint256 traderPaid = BUY; // exact-input
        console2.log("Trader paid (WETH):              %s", traderPaid);

        // Hook's claim-token balance is consumed by claimTeamFees; what flowed
        // through hook → factory → PFC is captured as the factory's incoming
        // WETH (which then immediately gets routed to PFC by claimTeamFees).
        // PFC's processFees splits to treasury + BR: the FINAL net flow per
        // recipient is what we want to report.
        // Use int256 since pre-existing carryover in FeeLocker can drain
        // negative during the collection chain.
        int256 burnerGot = int256(s2.burnRouterWeth) - int256(s0.burnRouterWeth);
        int256 treasuryGot = int256(s2.pfcTreasuryWeth) - int256(s0.pfcTreasuryWeth);
        int256 artistGot = int256(s2.artistWeth) - int256(s0.artistWeth);
        int256 pfcLeft = int256(s2.pfcSelfWeth) - int256(s0.pfcSelfWeth);
        int256 hookLeft = int256(s2.hookClaimWeth) - int256(s0.hookClaimWeth);
        int256 feeLockerLeft = int256(s2.feeLockerWeth) - int256(s0.feeLockerWeth);
        int256 factoryLeft = int256(s2.factoryWeth) - int256(s0.factoryWeth);

        console2.log("\nNet diffs (post collection chain, vs pre-swap):");
        console2.log("  artist treasury delta          (signed): %s", _signed(artistGot));
        console2.log("  PFC.treasury (artcoins) delta  (signed): %s", _signed(treasuryGot));
        console2.log("  BurnRouter delta               (signed): %s", _signed(burnerGot));
        console2.log("  hook claim tokens delta        (signed): %s", _signed(hookLeft));
        console2.log("  factory WETH delta             (signed): %s", _signed(factoryLeft));
        console2.log("  fee-locker WETH delta          (signed): %s", _signed(feeLockerLeft));
        console2.log("  PFC self WETH delta            (signed): %s", _signed(pfcLeft));

        int256 net =
            burnerGot + treasuryGot + artistGot + pfcLeft + hookLeft + feeLockerLeft + factoryLeft;
        console2.log("\nNet WETH inflow across all sinks: %s", _signed(net));
        console2.log("(This is the 'fee + carryover-drain' total, not strictly the fee)");
        console2.log("\nKey numbers from this swap alone:");
        console2.log(
            "  hook NEW protocol fee for this swap: %s wei (%s bps of input)",
            uint256(hookLeft + factoryLeft),
            uint256(hookLeft + factoryLeft) * 10_000 / traderPaid
        );
        // (hookLeft is what's still in the hook; factoryLeft is what got
        //  flushed to factory at the start of THIS swap from the prior swap's
        //  protocol fee. Their sum approximates 0.2% of trade input for the
        //  current swap if no claim happened mid-chain.)
    }

    // ─── helpers ─────────────────────────────────────────────────────

    struct Snap {
        uint256 burnRouterWeth;
        uint256 pfcTreasuryWeth;
        uint256 pfcSelfWeth;
        uint256 artistWeth;
        uint256 hookClaimWeth;
        uint256 factoryWeth;
        uint256 feeLockerWeth;
    }

    function _snap() internal view returns (Snap memory s) {
        s.burnRouterWeth = IERC20(WETH).balanceOf(BURN_ROUTER);
        // PFC's treasury is set in env; on Sepolia it's the deployer address.
        s.pfcTreasuryWeth = IERC20(WETH).balanceOf(ProtocolFeeController(payable(PFC)).treasury());
        s.pfcSelfWeth = IERC20(WETH).balanceOf(PFC);
        s.artistWeth = IERC20(WETH).balanceOf(ARTIST_TREASURY);
        s.hookClaimWeth = IPoolManager(POOL_MANAGER).balanceOf(HOOK, uint256(uint160(WETH)));
        s.factoryWeth = IERC20(WETH).balanceOf(FACTORY);
        s.feeLockerWeth = IERC20(WETH).balanceOf(FEE_LOCKER);
    }

    function _signed(int256 x) internal pure returns (string memory) {
        if (x < 0) return string.concat("-", vm.toString(uint256(-x)));
        return vm.toString(uint256(x));
    }

    function _logSnap(Snap memory s) internal pure {
        console2.log("  burnRouterWeth      %s", s.burnRouterWeth);
        console2.log("  pfcTreasuryWeth     %s", s.pfcTreasuryWeth);
        console2.log("  pfcSelfWeth         %s", s.pfcSelfWeth);
        console2.log("  artistWeth          %s", s.artistWeth);
        console2.log("  hookClaimWeth       %s", s.hookClaimWeth);
        console2.log("  factoryWeth         %s", s.factoryWeth);
        console2.log("  feeLockerWeth       %s", s.feeLockerWeth);
    }
}
