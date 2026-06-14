// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ArtCoinsFeeEscrow} from "../src/ArtCoinsFeeEscrow.sol";
import {ArtCoinsHookSkimFee} from "../src/hooks/ArtCoinsHookSkimFee.sol";
import {ArtCoinsPoolExtensionAllowlist} from "../src/hooks/ArtCoinsPoolExtensionAllowlist.sol";
import {
    IArtCoinsHookSkimFee,
    IReferralPayoutForHook,
    PCAttribution,
    PCSwapData
} from "../src/hooks/interfaces/IArtCoinsHookSkimFee.sol";
import {IArtCoinsHook} from "../src/interfaces/IArtCoinsHook.sol";
import {ArtCoinsMevLinearSkim} from "../src/mev-modules/ArtCoinsMevLinearSkim.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

contract MockTokenAdmin is ERC20 {
    address public admin;

    constructor(string memory n, string memory s, address a) ERC20(n, s) {
        admin = a;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setAdmin(address a) external {
        admin = a;
    }
}

/// @notice EOA-like recipient that accepts ETH.
contract EthRecipient {
    receive() external payable {}
}

/// @notice Stub IReferralPayoutForHook that records per-referrer receipts.
contract MockReferralPayout is IReferralPayoutForHook {
    mapping(address => uint256) public received;

    function notify(address referrer) external payable override {
        received[referrer] += msg.value;
    }
    receive() external payable {}
}

/// @title  ArtCoinsHookSkimFeeForkTest
/// @notice End-to-end fork test for the three-leg skim-fee hook. Deploys the
///         hook, linear-skim MEV module, an ETH/token pool, seeds LP, then
///         runs swaps and verifies the bounty / protocol / referral recipients
///         each receive the correct slice in-tx (the per-swap flush happens at
///         the end of `_afterSwap`).
///
/// Run:
///   forge test --match-contract ArtCoinsHookSkimFeeForkTest \
///     --fork-url $MAINNET_RPC_URL -vv
contract ArtCoinsHookSkimFeeForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    int24 constant TICK_SPACING = 200;
    uint24 constant LP_FEE_PPM = 10_000; // 1%
    uint24 constant BASELINE_BPS = 5000; // 5% of trader cost (denom 100_000)
    uint16 constant BOUNTY_BPS = 8000; // 80% of baseline → bounty
    // protocolBps (derived) = 10_000 - 8_000 = 2_000 (20%)

    ArtCoinsHookSkimFee internal hook;
    ArtCoinsMevLinearSkim internal mevModule;
    ArtCoinsPoolExtensionAllowlist internal allowlist;
    PoolModifyLiquidityTest internal liqRouter;
    PoolSwapTest internal swapRouter;
    MockTokenAdmin internal token;

    EthRecipient internal bountyR;
    EthRecipient internal protocolR;
    MockReferralPayout internal referralPayout;
    ArtCoinsFeeEscrow internal feeEscrow;

    PoolKey internal poolKey;
    bool internal _onFork;
    bool internal _tokenIsToken0;
    address internal admin = address(this);

    function setUp() public {
        if (POOL_MANAGER.code.length == 0) {
            console2.log("SKIPPING: not on mainnet fork");
            return;
        }
        _onFork = true;

        allowlist = new ArtCoinsPoolExtensionAllowlist(admin);
        token = new MockTokenAdmin("Test", "TEST", admin);
        bountyR = new EthRecipient();
        protocolR = new EthRecipient();
        referralPayout = new MockReferralPayout();
        feeEscrow = new ArtCoinsFeeEscrow(admin);

        // Mine hook address with the required flag bits.
        uint160 hookFlags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                // afterRemoveLiquidity (1<<8) is enabled in getHookPermissions for the
                // venue-scoped transfer-tax LP-exit attestation; it must be in the mined
                // flags or the hook constructor reverts HookAddressNotValid.
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory ctorArgs = abi.encode(
            POOL_MANAGER,
            address(this), // pretend-factory
            address(allowlist),
            WETH,
            address(feeEscrow)
        );
        (address hookAddr, bytes32 salt) = HookMiner.find(
            address(this), hookFlags, type(ArtCoinsHookSkimFee).creationCode, ctorArgs
        );
        hook = new ArtCoinsHookSkimFee{salt: salt}(
            POOL_MANAGER, address(this), address(allowlist), WETH, address(feeEscrow)
        );
        require(address(hook) == hookAddr, "Hook address mismatch");
        feeEscrow.addDepositor(address(hook));

        mevModule = new ArtCoinsMevLinearSkim();

        // Initial pool config: maxReferralBpsOfVolume = 0 (referrals disabled,
        // matching PC's v1 launch posture). The setter test below raises it.
        bytes memory feeData = abi.encode(
            IArtCoinsHookSkimFee.SkimHookFeeData({
                baselineSkimBps: BASELINE_BPS,
                bountyBps: BOUNTY_BPS,
                maxReferralBpsOfVolume: 0,
                lpFee: LP_FEE_PPM,
                bountyRecipient: payable(address(bountyR)),
                protocolRecipient: payable(address(protocolR)),
                referralPayout: payable(address(referralPayout)),
                quoteToken: address(0)
            })
        );
        bytes memory poolInit = abi.encode(
            IArtCoinsHook.PoolInitializationData({
                extension: address(0), extensionData: "", feeData: feeData
            })
        );
        int24 startingTick = -190_400;
        poolKey = IArtCoinsHook(address(hook))
            .initializePool(
                address(token),
                address(0), // paired = native ETH
                startingTick,
                TICK_SPACING,
                address(0), // locker irrelevant for this test
                address(mevModule),
                poolInit
            );
        _tokenIsToken0 = address(token) < address(0); // always false
        assertFalse(_tokenIsToken0, "ETH must sort as currency0");

        // Seed LP BEFORE MEV init (MEV gate would block).
        liqRouter = new PoolModifyLiquidityTest(IPoolManager(POOL_MANAGER));
        swapRouter = new PoolSwapTest(IPoolManager(POOL_MANAGER));
        uint256 lpAmount = 100_000_000e18;
        token.mint(address(this), lpAmount);
        IERC20(address(token)).approve(address(liqRouter), type(uint256).max);
        IERC20(address(token)).approve(address(swapRouter), type(uint256).max);

        vm.deal(address(this), 200 ether);

        int24 lower = -(startingTick + 60_000);
        int24 upper = -startingTick;
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(upper);
        uint128 L = LiquidityAmounts.getLiquidityForAmount1(sqrtA, sqrtB, lpAmount);
        liqRouter.modifyLiquidity{value: 100 ether}(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: lower,
                tickUpper: upper,
                liquidityDelta: int256(uint256(L)),
                salt: bytes32(0)
            }),
            ""
        );

        // Initialize the MEV module: default 68_690 → 5_000 over 69 minutes.
        IArtCoinsHook(address(hook)).initializeMevModule(poolKey, "");

        // Trader funding.
        vm.deal(address(this), 100 ether);
    }

    receive() external payable {}

    modifier onlyFork() {
        if (!_onFork) return;
        _;
    }

    // ─── helpers ──────────────────────────────────────────────────────────

    function _doExactInputBuy(uint256 ethIn) internal {
        _doExactInputBuyWithRef(ethIn, "");
    }

    /// @dev exactInput buy: ETH → token. amountSpecified < 0. Accepts an
    ///      optional `hookData` (PoolSwapData ABI-encoded with referrer
    ///      payload for tests that exercise the referral leg).
    function _doExactInputBuyWithRef(uint256 ethIn, bytes memory hookData) internal {
        bool zeroForOne = true; // ETH = currency0
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(ethIn),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        swapRouter.swap{value: ethIn}(
            poolKey,
            params,
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    function _doExactInputSell(uint256 tokenIn) internal {
        bool zeroForOne = false;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(tokenIn),
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        swapRouter.swap(
            poolKey,
            params,
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _encodeReferralHookData(address referrer, uint24 referralBps)
        internal
        pure
        returns (bytes memory)
    {
        PCSwapData memory inner = PCSwapData({
            attribution: PCAttribution({
                sourceId: bytes32(0),
                referrer: referrer,
                campaignId: bytes16(0),
                referralBps: referralBps
            }),
            extensionPayload: ""
        });
        IArtCoinsHook.PoolSwapData memory outer = IArtCoinsHook.PoolSwapData({
            mevModuleSwapData: "", poolExtensionSwapData: abi.encode(inner)
        });
        return abi.encode(outer);
    }

    // ─── initializePoolOpen: code-existence guard ────────────────────────

    /// @notice The `initializePoolOpen` code-existence guard only blocks
    ///         not-yet-deployed addresses: an already-deployed (non-factory)
    ///         token still opens a pool. Confirms the guard does not regress the
    ///         legitimate permissionless path.
    function test_initializePoolOpen_succeedsForDeployedToken() public onlyFork {
        MockTokenAdmin deployed = new MockTokenAdmin("Open", "OPEN", admin);
        assertGt(address(deployed).code.length, 0, "precondition: token deployed");

        bytes memory feeData = abi.encode(
            IArtCoinsHookSkimFee.SkimHookFeeData({
                baselineSkimBps: BASELINE_BPS,
                bountyBps: BOUNTY_BPS,
                maxReferralBpsOfVolume: 0,
                lpFee: LP_FEE_PPM,
                bountyRecipient: payable(address(bountyR)),
                protocolRecipient: payable(address(protocolR)),
                referralPayout: payable(address(referralPayout)),
                quoteToken: address(0)
            })
        );
        bytes memory poolInit = abi.encode(
            IArtCoinsHook.PoolInitializationData({
                extension: address(0), extensionData: "", feeData: feeData
            })
        );

        PoolKey memory openKey = IArtCoinsHook(address(hook))
            .initializePoolOpen(
                address(deployed), address(0), int24(-190_400), TICK_SPACING, poolInit
            );

        (uint160 sqrtPriceX96,,,) = IPoolManager(POOL_MANAGER).getSlot0(openKey.toId());
        assertGt(sqrtPriceX96, 0, "open pool initialized for a deployed token");
    }

    // ─── tests: per-swap flush of two pool legs ──────────────────────────

    /// @notice Buy at t=0 (during MEV window). Verifies both pool legs
    ///         (bounty, protocol) AND the anti-sniper extra (which is folded
    ///         into the bounty leg) get forwarded in-tx.
    function test_buyAtT0_flushesAllLegsInTx() public onlyFork {
        uint256 ethIn = 1 ether;

        uint256 brBefore = address(bountyR).balance;
        uint256 prBefore = feeEscrow.availableFees(address(protocolR), address(0));

        _doExactInputBuy(ethIn);

        uint256 brRecv = address(bountyR).balance - brBefore;
        uint256 prRecv = feeEscrow.availableFees(address(protocolR), address(0)) - prBefore;

        // Total skim = ~68_690 / 100_000 of 1 ETH.
        uint256 totalExpected = (ethIn * 68_690) / 100_000;
        // Baseline = 5% of input.
        uint256 baseline = (ethIn * BASELINE_BPS) / 100_000;
        uint256 antiSniperExtra = totalExpected - baseline;

        // Per-leg expectations.
        uint256 bountyShare = (baseline * BOUNTY_BPS) / 10_000;
        // protocolShare absorbs rounding dust.
        uint256 protocolShare = baseline - bountyShare;

        // bounty leg accrues bountyShare + antiSniperExtra.
        assertApproxEqAbs(brRecv, bountyShare + antiSniperExtra, 2, "bounty (incl anti-sniper)");
        assertApproxEqAbs(prRecv, protocolShare, 2, "protocol");

        // Total sum should equal the realised total skim.
        assertApproxEqAbs(brRecv + prRecv, totalExpected, 3, "legs sum to total");
    }

    /// @notice After the MEV window expires, anti-sniper extra is 0. Both
    ///         pool legs (bounty / protocol) still receive their slice of the
    ///         baseline skim.
    function test_postMevWindow_legsReceiveBaselineOnly() public onlyFork {
        skip(70 minutes);

        uint256 ethIn = 1 ether;
        uint256 brBefore = address(bountyR).balance;
        uint256 prBefore = feeEscrow.availableFees(address(protocolR), address(0));

        _doExactInputBuy(ethIn);

        uint256 brRecv = address(bountyR).balance - brBefore;
        uint256 prRecv = feeEscrow.availableFees(address(protocolR), address(0)) - prBefore;

        uint256 baseline = (ethIn * BASELINE_BPS) / 100_000;
        uint256 bountyShare = (baseline * BOUNTY_BPS) / 10_000;
        uint256 protocolShare = baseline - bountyShare;

        assertApproxEqAbs(brRecv, bountyShare, 1, "bounty");
        assertApproxEqAbs(prRecv, protocolShare, 1, "protocol");
        // No anti-sniper extra post-window.
        assertApproxEqAbs(brRecv + prRecv, baseline, 2, "total = baseline");
    }

    /// @notice Public LP adds are blocked during the MEV window. After the
    ///         window closes, the skim module's `operational()` returns false
    ///         and the gate is lifted.
    function test_lpAddBlockedDuringMev_allowedAfter() public onlyFork {
        int24 lower = -200;
        int24 upper = 200;

        vm.expectRevert();
        liqRouter.modifyLiquidity{value: 0.001 ether}(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: lower, tickUpper: upper, liquidityDelta: 1, salt: bytes32(uint256(1))
            }),
            ""
        );

        skip(70 minutes);
        assertFalse(mevModule.operational(poolKey.toId()), "module no longer operational");
    }

    /// @notice Integration regression: a swap AFTER the base hook's generic
    ///         15-min cap must NOT unlock public LP adds while the skim window
    ///         is still open. Pre-fix, that swap's `_runMevModule` flipped
    ///         `mevModuleEnabled=false`, and `_beforeAddLiquidity` fell through
    ///         to the (also-expired) generic gate — opening adds at ~15m while
    ///         the skim decay was still well above baseline. The lock now keys
    ///         solely on the skim module's `operational()`, so it holds for the
    ///         full ~69m window regardless of swap activity.
    function test_lpAddStaysBlocked_afterSwapPastGenericCap() public onlyFork {
        // A swap during the early window.
        _doExactInputBuy(0.05 ether);

        // Advance past the 15-min generic cap but stay inside the 69-min skim
        // window, then swap again. Pre-fix this second swap cleared the generic
        // flag and unlocked adds; it must not anymore.
        skip(20 minutes);
        assertTrue(mevModule.operational(poolKey.toId()), "skim window still open");
        _doExactInputBuy(0.05 ether);

        // Public LP add must still revert — the skim window owns the lock.
        vm.expectRevert();
        liqRouter.modifyLiquidity{value: 0.001 ether}(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -200, tickUpper: 200, liquidityDelta: 1, salt: bytes32(uint256(2))
            }),
            ""
        );

        // Once the skim window closes, the lock lifts.
        skip(50 minutes); // total > 69m
        assertFalse(mevModule.operational(poolKey.toId()), "skim window closed");
    }

    /// @notice exactInput SELL (token → ETH): both pool legs receive their
    ///         slice from the output-side ETH skim in-tx.
    function test_exactInputSell_legsReceiveOutputSkim() public onlyFork {
        // Buy first to get some token.
        _doExactInputBuy(5 ether);
        skip(70 minutes); // post-MEV so we don't have to predict the decay value

        uint256 tokenBal = IERC20(address(token)).balanceOf(address(this));
        assertGt(tokenBal, 0);

        uint256 brBefore = address(bountyR).balance;
        uint256 prBefore = feeEscrow.availableFees(address(protocolR), address(0));

        _doExactInputSell(tokenBal / 2);

        uint256 brRecv = address(bountyR).balance - brBefore;
        uint256 prRecv = feeEscrow.availableFees(address(protocolR), address(0)) - prBefore;

        // Both pool legs received > 0 ETH from the sell's output skim.
        assertGt(brRecv, 0, "bounty got something");
        assertGt(prRecv, 0, "protocol got something");
    }

    // ─── tests: setMaxReferralBpsOfVolume (the new admin setter) ─────────

    /// @notice Setter end-to-end: admin sets cap, next swap with a referral
    ///         payload pays the referrer at the new cap.
    function test_setMaxRef_nextSwapUsesNewCap() public onlyFork {
        skip(70 minutes); // post-MEV so the math is just baseline.

        PoolId pid = poolKey.toId();
        (,, uint24 capBefore,,,,,) = hook.skimConfig(pid);
        assertEq(capBefore, 0, "cap starts at 0 per setUp");

        // Raise the cap to 500 (0.5% of volume).
        hook.setMaxReferralBpsOfVolume(poolKey, 500);
        (,, uint24 capAfter,,,,,) = hook.skimConfig(pid);
        assertEq(capAfter, 500, "cap raised to 500");

        // Run a swap with a referrer payload. The PCSwapData attribution
        // requests `referralBps = 800`; with cap = 500, the referrer should
        // get the cap-clamped amount.
        address referrer = makeAddr("referrer");
        bytes memory hookData = _encodeReferralHookData(referrer, 800);

        uint256 ethIn = 1 ether;
        _doExactInputBuyWithRef(ethIn, hookData);

        // Referrer should have received exactly volume * 500 / 100_000.
        // (Or less if the protocol slice can't cover it, but with bountyBps=8_000
        // the protocol slice = baseline*0.20 = 0.05*0.20 = 0.01 ETH, and the
        // requested ref at cap = 1 * 0.005 = 0.005 ETH — protocol can cover it.)
        uint256 expectedRef = (ethIn * 500) / 100_000;
        assertEq(referralPayout.received(referrer), expectedRef, "referrer paid at cap");
    }

    /// @notice Setter zero-cap means even a non-zero referralBps in the
    ///         payload gets clamped to zero — the launch posture.
    function test_setMaxRef_zeroCapDisablesReferrals() public onlyFork {
        skip(70 minutes);

        PoolId pid = poolKey.toId();
        (,, uint24 cap,,,,,) = hook.skimConfig(pid);
        assertEq(cap, 0, "cap starts at 0");

        address referrer = makeAddr("referrer");
        bytes memory hookData = _encodeReferralHookData(referrer, 800);

        _doExactInputBuyWithRef(1 ether, hookData);

        assertEq(referralPayout.received(referrer), 0, "no referral paid when cap=0");
    }

    /// @notice Setter rejects values above MAX_REFERRAL_CAP_OF_VOLUME (1_000).
    function test_setMaxRef_revertsAboveHardCap() public onlyFork {
        vm.expectRevert(IArtCoinsHookSkimFee.MaxReferralTooHigh.selector);
        hook.setMaxReferralBpsOfVolume(poolKey, 1001);
    }

    /// @notice Setter rejects non-admin callers.
    function test_setMaxRef_revertsForNonAdmin() public onlyFork {
        vm.prank(makeAddr("not-admin"));
        vm.expectRevert(IArtCoinsHook.NotTokenAdmin.selector);
        hook.setMaxReferralBpsOfVolume(poolKey, 500);
    }

    /// @notice After admin rotation, the new admin's calls pass and the
    ///         old admin's revert. Mirrors PC's TokenAdminPoker handoff.
    function test_setMaxRef_followsAdminRotation() public onlyFork {
        address newAdmin = makeAddr("newAdmin");
        token.setAdmin(newAdmin);

        // Old admin (this test contract) is no longer the admin.
        vm.expectRevert(IArtCoinsHook.NotTokenAdmin.selector);
        hook.setMaxReferralBpsOfVolume(poolKey, 500);

        vm.prank(newAdmin);
        hook.setMaxReferralBpsOfVolume(poolKey, 500);
        (,, uint24 cap,,,,,) = hook.skimConfig(poolKey.toId());
        assertEq(cap, 500);
    }

    // ─── new-behavior coverage: failure paths of the fresh-only flush ────

    /// @dev Spin up a second baseline-only pool (no MEV module) on the same
    ///      hook with caller-chosen recipients, so the failure tests can use a
    ///      rejecting bounty / referral recipient. LP is seeded so swaps route.
    function _initPlainPool(
        MockTokenAdmin tok,
        address payable bountyRecipient,
        address payable protocolRecipient,
        address payable referralPayoutAddr,
        uint24 maxRef
    ) internal returns (PoolKey memory key) {
        bytes memory feeData = abi.encode(
            IArtCoinsHookSkimFee.SkimHookFeeData({
                baselineSkimBps: BASELINE_BPS,
                bountyBps: BOUNTY_BPS,
                maxReferralBpsOfVolume: maxRef,
                lpFee: LP_FEE_PPM,
                bountyRecipient: bountyRecipient,
                protocolRecipient: protocolRecipient,
                referralPayout: referralPayoutAddr,
                quoteToken: address(0)
            })
        );
        bytes memory poolInit = abi.encode(
            IArtCoinsHook.PoolInitializationData({
                extension: address(0), extensionData: "", feeData: feeData
            })
        );
        int24 startingTick = -190_400;
        key = IArtCoinsHook(address(hook))
            .initializePool(
                address(tok),
                address(0),
                startingTick,
                TICK_SPACING,
                address(0),
                address(0),
                poolInit
            );

        uint256 lpAmount = 100_000_000e18;
        tok.mint(address(this), lpAmount);
        IERC20(address(tok)).approve(address(liqRouter), type(uint256).max);
        IERC20(address(tok)).approve(address(swapRouter), type(uint256).max);
        int24 lower = -(startingTick + 60_000);
        int24 upper = -startingTick;
        uint128 L = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), lpAmount
        );
        liqRouter.modifyLiquidity{value: 100 ether}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: lower,
                tickUpper: upper,
                liquidityDelta: int256(uint256(L)),
                salt: bytes32(0)
            }),
            ""
        );
    }

    function _buyOn(PoolKey memory key, uint256 ethIn, bytes memory hookData) internal {
        swapRouter.swap{value: ethIn}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(ethIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    /// @notice The bid leg is the live-bid heartbeat: if the bounty recipient
    ///         rejects ETH, the swap REVERTS (no held/retry). Spec invariant.
    function test_bidLegRevertsWhenRecipientRejects() public onlyFork {
        MockTokenAdmin tok2 = new MockTokenAdmin("T2", "T2", admin);
        RejectingRecipient badBounty = new RejectingRecipient();
        PoolKey memory key2 = _initPlainPool(
            tok2,
            payable(address(badBounty)),
            payable(address(protocolR)),
            payable(address(referralPayout)),
            0
        );
        vm.deal(address(this), 10 ether);
        vm.expectRevert(); // BidForwardFailed bubbles up through the swap
        _buyOn(key2, 1 ether, "");
    }

    /// @notice The referral leg is non-critical: if ReferralPayout reverts, the
    ///         amount folds into the protocol escrow instead of being held, and
    ///         the swap still succeeds. So the FULL protocol slice (net + folded
    ///         referral) ends up escrowed under the protocol recipient.
    function test_referralFoldsToProtocolEscrowWhenPayoutReverts() public onlyFork {
        MockTokenAdmin tok3 = new MockTokenAdmin("T3", "T3", admin);
        RejectingReferralPayout badPayout = new RejectingReferralPayout();
        PoolKey memory key3 = _initPlainPool(
            tok3,
            payable(address(bountyR)),
            payable(address(protocolR)),
            payable(address(badPayout)),
            1000 // allow referrals
        );

        uint256 ethIn = 1 ether;
        uint256 escrowBefore = feeEscrow.availableFees(address(protocolR), address(0));
        vm.deal(address(this), 10 ether);
        bytes memory refData = _encodeReferralHookData(makeAddr("ref"), 250);
        _buyOn(key3, ethIn, refData); // does NOT revert

        uint256 escrowed = feeEscrow.availableFees(address(protocolR), address(0)) - escrowBefore;
        uint256 baseline = (ethIn * BASELINE_BPS) / 100_000;
        uint256 bountyShare = (baseline * BOUNTY_BPS) / 10_000;
        uint256 protocolShare = baseline - bountyShare;
        assertApproxEqAbs(escrowed, protocolShare, 3, "protocol + folded referral escrowed");
    }
}

/// @notice Recipient that rejects all ETH (for the bid-leg revert test).
contract RejectingRecipient {
    receive() external payable {
        revert("nope");
    }
}

/// @notice ReferralPayout stub whose notify always reverts (for the fold test).
contract RejectingReferralPayout is IReferralPayoutForHook {
    function notify(address) external payable override {
        revert("nope");
    }
}
