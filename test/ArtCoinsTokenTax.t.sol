// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ArtCoinsToken} from "../src/ArtCoinsToken.sol";
import {IArtCoinsTaxable, TaxConfig, TaxVenue} from "../src/interfaces/IArtCoinsTaxable.sol";
import {Test} from "forge-std/Test.sol";

/// @title  ArtCoinsTokenTaxTest
/// @notice Behavioral unit tests for the venue-scoped buy-side transfer tax on
///         `ArtCoinsToken` (no fork — pure token logic). Mirrors the integration
///         coverage in permanent-collection's `TaxedTokenForkTest`, but exercises
///         the token in isolation: a chosen `poolManager` + derived V2/V3
///         addresses stand in for venues, and prank'd transfers model buys /
///         sells / sends. Confirms the immutable transfer path is correct in the
///         repo that owns it.
contract ArtCoinsTokenTaxTest is Test {
    // Stand-in venue / role addresses (any address works for unit purposes).
    address constant POOL_MANAGER = address(0x1111);
    address constant HOOK = address(0x2222);
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // V2/V3 derivation inputs (mainnet-shaped; the exact values don't matter for
    // unit logic — only that the token derives the SAME address we do).
    address constant UNIV2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    bytes32 constant UNIV2_INIT =
        0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;
    address constant UNIV3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    bytes32 constant UNIV3_INIT =
        0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    address admin = address(0xA11CE);
    address exemptA = address(0xE1);
    address exemptB = address(0xE2);
    address trader = address(0x7AADE7);
    address bob = address(0xB0B);

    uint256 constant SUPPLY = 1_000_000e18;
    uint16 constant RATE = 500; // 5%
    uint256 constant DENOM = 10_000;

    ArtCoinsToken token; // tax-enabled
    uint24[] v3Tiers;

    function setUp() public {
        v3Tiers = new uint24[](1);
        v3Tiers[0] = 3000;
        token = _deployTaxed();
        // The deployer (this test) holds the full supply.
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    // ─── construction helpers ───────────────────────────────────────────────

    function _taxConfig() internal view returns (TaxConfig memory tc) {
        tc.enabled = true;
        tc.taxBps = RATE;
        tc.taxBpsMax = RATE;
        tc.burnAddress = DEAD;
        tc.poolManager = POOL_MANAGER;
        tc.canonicalHook = HOOK;
        tc.pairedToken = address(0); // native ETH
        tc.canonicalPoolFee = 0x800000;
        tc.canonicalTickSpacing = 200;
        tc.exempt = new address[](2);
        tc.exempt[0] = exemptA;
        tc.exempt[1] = exemptB;
        tc.venues = new TaxVenue[](2);
        tc.venues[0] = TaxVenue({
            kind: 1, factory: UNIV2_FACTORY, initCodeHash: UNIV2_INIT, counterToken: WETH, v3Fee: 0
        });
        tc.venues[1] = TaxVenue({
            kind: 2,
            factory: UNIV3_FACTORY,
            initCodeHash: UNIV3_INIT,
            counterToken: WETH,
            v3Fee: 3000
        });
    }

    function _deployTaxed() internal returns (ArtCoinsToken t) {
        t = new ArtCoinsToken("Taxed", "TAX", SUPPLY, admin, "", "", "", address(0), _taxConfig());
    }

    /// @dev Re-derive a Uniswap-V2-style pair address (mirrors the token ctor).
    function _v2Pair(address tok, address counter) internal pure returns (address) {
        (address t0, address t1) = tok < counter ? (tok, counter) : (counter, tok);
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff", UNIV2_FACTORY, keccak256(abi.encodePacked(t0, t1)), UNIV2_INIT
                        )
                    )
                )
            )
        );
    }

    /// @dev Re-derive a Uniswap-V3-style pool address (mirrors the token ctor).
    function _v3Pool(address tok, address counter, uint24 fee) internal pure returns (address) {
        (address t0, address t1) = tok < counter ? (tok, counter) : (counter, tok);
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff", UNIV3_FACTORY, keccak256(abi.encode(t0, t1, fee)), UNIV3_INIT
                        )
                    )
                )
            )
        );
    }

    /// @dev Fund a "venue" address with `amt` PCT (test -> venue is sender=this,
    ///      not a venue, so it's an untaxed move).
    function _fundVenue(address venue, uint256 amt) internal {
        token.transfer(venue, amt);
    }

    /// @dev Expected tax on `amt` at the launch rate. A function (runtime) so the
    ///      uint16 `RATE` is promoted to uint256 rather than constant-folded into
    ///      uint16 (which would overflow for 18-decimal amounts).
    function _tax(uint256 amt) internal pure returns (uint256) {
        return (amt * uint256(RATE)) / DENOM;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Dormant (default-off) token — vanilla ERC20
    // ════════════════════════════════════════════════════════════════════════

    function test_dormant_isVanilla() public {
        TaxConfig memory off; // enabled = false
        ArtCoinsToken d =
            new ArtCoinsToken("Off", "OFF", SUPPLY, admin, "", "", "", address(0), off);
        assertFalse(d.taxEnabled());
        assertEq(d.taxBps(), 0);
        assertEq(d.taxBpsMax(), 0);
        assertEq(d.canonicalPoolId(), bytes32(0));
        assertEq(d.canonicalHook(), address(0));
        assertFalse(d.isTaxVenue(POOL_MANAGER));

        // A transfer FROM the (would-be) PoolManager is a plain transfer.
        d.transfer(POOL_MANAGER, 1000e18);
        uint256 deadBefore = d.balanceOf(DEAD);
        vm.prank(POOL_MANAGER);
        d.transfer(trader, 1000e18);
        assertEq(d.balanceOf(trader), 1000e18, "dormant: full amount");
        assertEq(d.balanceOf(DEAD), deadBefore, "dormant: nothing burned");
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Construction + venue derivation
    // ════════════════════════════════════════════════════════════════════════

    function test_enabled_views() public view {
        assertTrue(token.taxEnabled());
        assertEq(token.taxBps(), RATE);
        assertEq(token.taxBpsMax(), RATE);
        assertEq(token.taxBurnAddress(), DEAD);
        assertEq(token.canonicalHook(), HOOK);
    }

    function test_poolManager_isVenue() public view {
        assertTrue(token.isTaxVenue(POOL_MANAGER));
    }

    function test_derivedV2Pair_isVenue() public view {
        assertTrue(token.isTaxVenue(_v2Pair(address(token), WETH)), "derived V2 pair is a venue");
    }

    function test_derivedV3Pool_isVenue() public view {
        assertTrue(
            token.isTaxVenue(_v3Pool(address(token), WETH, 3000)), "derived V3 pool is a venue"
        );
    }

    function test_nonVenue_isNotVenue() public view {
        assertFalse(token.isTaxVenue(trader));
        assertFalse(token.isTaxVenue(_v3Pool(address(token), WETH, 500)), "untaxed fee tier");
    }

    function test_canonicalPoolId_matchesV4Formula() public view {
        // ETH (address(0)) sorts first; token is currency1.
        bytes32 expected =
            keccak256(abi.encode(address(0), address(token), uint24(0x800000), int24(200), HOOK));
        assertEq(token.canonicalPoolId(), expected);
    }

    function test_exempt_views() public view {
        assertTrue(token.isTaxExempt(exemptA));
        assertTrue(token.isTaxExempt(exemptB));
        assertFalse(token.isTaxExempt(trader));
    }

    function test_constructor_rejectsRateAboveCap() public {
        TaxConfig memory tc = _taxConfig();
        tc.taxBps = tc.taxBpsMax + 1;
        vm.expectRevert(ArtCoinsToken.TaxConfigInvalid.selector);
        new ArtCoinsToken("X", "X", SUPPLY, admin, "", "", "", address(0), tc);
    }

    function test_constructor_rejectsCapAboveAbsoluteMax() public {
        TaxConfig memory tc = _taxConfig();
        tc.taxBpsMax = 2001; // > TAX_BPS_ABSOLUTE_MAX (2000)
        tc.taxBps = 2001;
        vm.expectRevert(ArtCoinsToken.TaxConfigInvalid.selector);
        new ArtCoinsToken("X", "X", SUPPLY, admin, "", "", "", address(0), tc);
    }

    function test_constructor_rejectsZeroBurnHookOrPm() public {
        TaxConfig memory tc = _taxConfig();
        tc.burnAddress = address(0);
        vm.expectRevert(ArtCoinsToken.TaxConfigInvalid.selector);
        new ArtCoinsToken("X", "X", SUPPLY, admin, "", "", "", address(0), tc);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Tax fires only on venue -> non-exempt
    // ════════════════════════════════════════════════════════════════════════

    function test_venueToTrader_taxed() public {
        _fundVenue(POOL_MANAGER, 1000e18);
        uint256 deadBefore = token.balanceOf(DEAD);
        uint256 amt = 1000e18;
        uint256 tax = _tax(amt);

        vm.expectEmit(true, true, false, true, address(token));
        emit IArtCoinsTaxableEvents.TaxApplied(POOL_MANAGER, trader, amt, tax, amt - tax);
        vm.prank(POOL_MANAGER);
        token.transfer(trader, amt);

        assertEq(token.balanceOf(trader), amt - tax, "trader gets net");
        assertEq(token.balanceOf(DEAD) - deadBefore, tax, "5% burned");
    }

    function test_venueToExempt_untaxed() public {
        _fundVenue(POOL_MANAGER, 1000e18);
        uint256 deadBefore = token.balanceOf(DEAD);
        vm.prank(POOL_MANAGER);
        token.transfer(exemptA, 1000e18);
        assertEq(token.balanceOf(exemptA), 1000e18, "exempt recipient gets full");
        assertEq(token.balanceOf(DEAD), deadBefore, "exempt: nothing burned");
    }

    function test_derivedVenueToTrader_taxed() public {
        address pair = _v2Pair(address(token), WETH);
        _fundVenue(pair, 1000e18);
        uint256 deadBefore = token.balanceOf(DEAD);
        uint256 amt = 800e18;
        vm.prank(pair);
        token.transfer(trader, amt);
        assertEq(token.balanceOf(DEAD) - deadBefore, _tax(amt), "V2 venue outflow taxed");
    }

    function test_walletToWallet_untaxed() public {
        token.transfer(trader, 1000e18); // this -> trader (sender not a venue)
        uint256 deadBefore = token.balanceOf(DEAD);
        vm.prank(trader);
        token.transfer(bob, 1000e18); // trader -> bob
        assertEq(token.balanceOf(bob), 1000e18, "wallet send full");
        assertEq(token.balanceOf(DEAD), deadBefore, "wallet send untaxed");
    }

    function test_traderToVenue_untaxed_sell() public {
        token.transfer(trader, 1000e18);
        uint256 deadBefore = token.balanceOf(DEAD);
        // Selling = PCT INTO a venue; sender is the trader, not the venue.
        vm.prank(trader);
        token.transfer(POOL_MANAGER, 1000e18);
        assertEq(token.balanceOf(POOL_MANAGER), 1000e18, "into-venue full (no revert)");
        assertEq(token.balanceOf(DEAD), deadBefore, "sell untaxed");
    }

    function test_transferFrom_fromVenue_taxed_fullAllowanceDebit() public {
        _fundVenue(POOL_MANAGER, 1000e18);
        uint256 amt = 1000e18;
        // The venue approves `bob` as spender for the full gross amount.
        vm.prank(POOL_MANAGER);
        token.approve(bob, amt);

        uint256 deadBefore = token.balanceOf(DEAD);
        vm.prank(bob);
        token.transferFrom(POOL_MANAGER, trader, amt);

        uint256 tax = _tax(amt);
        assertEq(token.balanceOf(trader), amt - tax, "transferFrom: trader gets net");
        assertEq(token.balanceOf(DEAD) - deadBefore, tax, "transferFrom: taxed");
        assertEq(token.allowance(POOL_MANAGER, bob), 0, "allowance debited the FULL gross amount");
    }

    function test_permit2_fromVenue_taxed() public {
        _fundVenue(POOL_MANAGER, 1000e18);
        uint256 amt = 500e18;
        uint256 deadBefore = token.balanceOf(DEAD);
        // Permit2 has infinite allowance over every holder (Solady), no approve needed.
        vm.prank(PERMIT2);
        token.transferFrom(POOL_MANAGER, trader, amt);
        assertEq(token.balanceOf(DEAD) - deadBefore, _tax(amt), "permit2 buy taxed");
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Canonical-exemption budget (attest)
    // ════════════════════════════════════════════════════════════════════════

    function test_attest_hookOnly() public {
        bytes32 pid = token.canonicalPoolId();
        vm.prank(bob);
        vm.expectRevert(ArtCoinsToken.NotCanonicalHook.selector);
        token.attestCanonicalBudget(pid, 1e18);
        // The hook is allowed.
        vm.prank(HOOK);
        token.attestCanonicalBudget(pid, 1e18);
    }

    function test_attest_amountPinned_consumed() public {
        _fundVenue(POOL_MANAGER, 1000e18);
        bytes32 pid = token.canonicalPoolId();
        vm.prank(HOOK);
        token.attestCanonicalBudget(pid, 400e18);

        // Exactly-budgeted venue outflow is exempt.
        uint256 deadBefore = token.balanceOf(DEAD);
        vm.prank(POOL_MANAGER);
        token.transfer(trader, 400e18);
        assertEq(token.balanceOf(trader), 400e18, "budgeted amount exempt");
        assertEq(token.balanceOf(DEAD), deadBefore, "no burn within budget");

        // Budget spent -> the next venue outflow is taxed.
        vm.prank(POOL_MANAGER);
        token.transfer(trader, 200e18);
        assertEq(token.balanceOf(DEAD) - deadBefore, _tax(200e18), "post-budget taxed");
    }

    function test_attest_partialBudget_taxesRemainder() public {
        _fundVenue(POOL_MANAGER, 1000e18);
        bytes32 pid = token.canonicalPoolId();
        vm.prank(HOOK);
        token.attestCanonicalBudget(pid, 300e18); // budget < transfer

        uint256 deadBefore = token.balanceOf(DEAD);
        vm.prank(POOL_MANAGER);
        token.transfer(trader, 1000e18); // 300 exempt, 700 taxable
        uint256 expectedTax = _tax(700e18);
        assertEq(token.balanceOf(DEAD) - deadBefore, expectedTax, "only the unbudgeted part taxed");
    }

    function test_attest_accumulatesWithinTx() public {
        _fundVenue(POOL_MANAGER, 1000e18);
        bytes32 pid = token.canonicalPoolId();
        vm.startPrank(HOOK);
        token.attestCanonicalBudget(pid, 250e18);
        token.attestCanonicalBudget(pid, 250e18);
        vm.stopPrank();

        uint256 deadBefore = token.balanceOf(DEAD);
        vm.prank(POOL_MANAGER);
        token.transfer(trader, 500e18); // == accumulated budget
        assertEq(token.balanceOf(DEAD), deadBefore, "accumulated budget exempts the sum");
    }

    /// @notice Exempt-outflow budget leak (the fix): the canonical-exemption
    ///         budget is drawn down on EVERY venue outflow — including ones to
    ///         an EXEMPT recipient — so it cannot survive a canonical buy whose
    ///         PCT went to an exempt address (a buy-and-burn / the LP locker)
    ///         and then be harvested tax-free by a LATER side-pool outflow in
    ///         the same tx. Whole sequence is one test = one tx, so the
    ///         transient budget persists across the three steps.
    ///
    ///         Pre-fix: `_consumeCanonicalBudget` ran ONLY in the `!_taxExempt`
    ///         branch, so step 2 left the full budget B intact and step 3 rode
    ///         it tax-free — the assertion `deadBefore == balanceOf(DEAD)`
    ///         after step 3 would hold (no burn), failing this test's
    ///         expectation that step 3 IS taxed.
    function test_attest_exemptOutflow_consumesBudget_noLeak() public {
        _fundVenue(POOL_MANAGER, 2000e18);
        bytes32 pid = token.canonicalPoolId();

        uint256 B = 1000e18;

        // 1. Attest budget B as the canonical hook.
        vm.prank(HOOK);
        token.attestCanonicalBudget(pid, B);

        // 2. Canonical buy whose PCT goes to an EXEMPT recipient. Untaxed
        //    (exempt), but it MUST consume the budget under the fix.
        uint256 deadBeforeExempt = token.balanceOf(DEAD);
        vm.prank(POOL_MANAGER);
        token.transfer(exemptA, B);
        assertEq(token.balanceOf(exemptA), B, "exempt recipient gets full (untaxed)");
        assertEq(token.balanceOf(DEAD), deadBeforeExempt, "exempt outflow burns nothing");

        // 3. A LATER venue -> NON-exempt outflow (a side-pool buy). The budget
        //    was drawn to 0 by step 2, so this MUST be taxed. This is the key
        //    assertion: pre-fix the leftover budget B would exempt it.
        uint256 deadBeforeTrader = token.balanceOf(DEAD);
        uint256 sidePoolAmt = 400e18;
        vm.prank(POOL_MANAGER);
        token.transfer(trader, sidePoolAmt);

        uint256 expectedTax = _tax(sidePoolAmt);
        assertEq(
            token.balanceOf(DEAD) - deadBeforeTrader,
            expectedTax,
            "side-pool outflow taxed: exempt buy consumed the budget (no leak)"
        );
        assertEq(
            token.balanceOf(trader), sidePoolAmt - expectedTax, "trader gets net of side-pool buy"
        );
    }

    /// @notice Positive control for the fix: a venue -> NON-exempt outflow that
    ///         is itself directly covered by freshly-attested budget is STILL
    ///         tax-free. Proves the budget-consume-on-every-outflow change did
    ///         not break the legitimate canonical-buy exemption.
    function test_attest_freshBudget_nonExemptStillExempt_control() public {
        _fundVenue(POOL_MANAGER, 1000e18);
        bytes32 pid = token.canonicalPoolId();

        uint256 B = 600e18;
        vm.prank(HOOK);
        token.attestCanonicalBudget(pid, B);

        uint256 deadBefore = token.balanceOf(DEAD);
        vm.prank(POOL_MANAGER);
        token.transfer(trader, B); // exactly covered by budget
        assertEq(token.balanceOf(trader), B, "budgeted canonical buy to non-exempt is tax-free");
        assertEq(token.balanceOf(DEAD), deadBefore, "no burn within budget");
    }

    /// @notice Stronger leak proof: an exempt outflow of LESS than the budget
    ///         only partially consumes it, and the next non-exempt outflow is
    ///         taxed on exactly the amount beyond the leftover budget. Confirms
    ///         the exempt-outflow consumption is amount-pinned, not all-or-none.
    function test_attest_partialExemptOutflow_consumesProRata_noLeak() public {
        _fundVenue(POOL_MANAGER, 2000e18);
        bytes32 pid = token.canonicalPoolId();

        // Budget 1000; exempt outflow of 300 consumes 300, leaving 700.
        vm.prank(HOOK);
        token.attestCanonicalBudget(pid, 1000e18);
        vm.prank(POOL_MANAGER);
        token.transfer(exemptA, 300e18); // consumes 300 of the budget

        // Non-exempt outflow of 1000: 700 covered by leftover budget, 300 taxed.
        uint256 deadBefore = token.balanceOf(DEAD);
        vm.prank(POOL_MANAGER);
        token.transfer(trader, 1000e18);
        uint256 expectedTax = _tax(300e18); // only the 300 beyond leftover budget
        assertEq(
            token.balanceOf(DEAD) - deadBefore,
            expectedTax,
            "only the part beyond leftover (post-exempt) budget is taxed"
        );
    }

    function test_attest_wrongPoolId_ignored() public {
        _fundVenue(POOL_MANAGER, 1000e18);
        vm.prank(HOOK);
        token.attestCanonicalBudget(keccak256("not-canonical"), 1000e18);

        uint256 deadBefore = token.balanceOf(DEAD);
        vm.prank(POOL_MANAGER);
        token.transfer(trader, 1000e18);
        assertEq(
            token.balanceOf(DEAD) - deadBefore,
            _tax(1000e18),
            "wrong-pool attest grants no budget -> taxed"
        );
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Rate setter — admin-gated + bounded
    // ════════════════════════════════════════════════════════════════════════

    function test_setTaxBps_adminOnly() public {
        vm.prank(bob);
        vm.expectRevert(ArtCoinsToken.NotAdmin.selector);
        token.setTaxBps(100);
    }

    function test_setTaxBps_rejectsAboveCap() public {
        vm.prank(admin);
        vm.expectRevert(ArtCoinsToken.TaxBpsTooHigh.selector);
        token.setTaxBps(RATE + 1);
    }

    function test_setTaxBps_lowerThenZeroDisables() public {
        vm.prank(admin);
        token.setTaxBps(100);
        assertEq(token.taxBps(), 100);

        vm.prank(admin);
        token.setTaxBps(0);
        assertEq(token.taxBps(), 0);

        // Rate 0 -> a venue outflow is untaxed.
        _fundVenue(POOL_MANAGER, 1000e18);
        uint256 deadBefore = token.balanceOf(DEAD);
        vm.prank(POOL_MANAGER);
        token.transfer(trader, 1000e18);
        assertEq(token.balanceOf(DEAD), deadBefore, "rate 0 => no tax");
    }

    function test_setTaxBps_dormantTokenReverts() public {
        TaxConfig memory off;
        ArtCoinsToken d =
            new ArtCoinsToken("Off", "OFF", SUPPLY, admin, "", "", "", address(0), off);
        vm.prank(admin);
        vm.expectRevert(ArtCoinsToken.TaxNotEnabled.selector);
        d.setTaxBps(100);
    }
}

/// @dev Event signature mirror for `vm.expectEmit` (the token declares it).
interface IArtCoinsTaxableEvents {
    event TaxApplied(
        address indexed from, address indexed to, uint256 gross, uint256 tax, uint256 net
    );
}
