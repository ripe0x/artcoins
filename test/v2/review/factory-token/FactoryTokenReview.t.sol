// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {ArtCoinsFactory} from "../../../../src/ArtCoinsFactory.sol";
import {ArtCoinsFeeEscrow} from "../../../../src/ArtCoinsFeeEscrow.sol";
import {ArtCoinsToken} from "../../../../src/ArtCoinsToken.sol";
import {IArtCoinsFactory} from "../../../../src/interfaces/IArtCoinsFactory.sol";
import {IArtCoinsFeeLocker} from "../../../../src/interfaces/IArtCoinsFeeLocker.sol";
import {TaxConfig, TaxVenue} from "../../../../src/interfaces/IArtCoinsTaxable.sol";

import {
    FTEscrowFeeOwner, FTMockExtension, FTMockHook, FTMockLocker
} from "./FactoryTokenMocks.sol";

/// @title  FactoryTokenReview
/// @notice proof tests for docs/v2/review/contracts-factory-token.md. every
///         `test_bug_*` PASSES by asserting the bad outcome; when v2 fixes the
///         bug, flip the assertion and keep it as a regression test.
///         `test_holds_*` pin claims that were checked and hold.
///         no pool manager: hook / locker / extension are minimal stand ins
///         (see FactoryTokenMocks.sol). the factory, deployer library, token
///         and escrow are the real contracts.
contract FactoryTokenReviewTest is Test {
    uint256 constant FEE = 0.069 ether;
    uint24 constant DYN = 0x800000;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant PM = address(0x1111); // stands in for the v4 pool manager
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant UNIV2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    bytes32 constant UNIV2_INIT = 0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;
    address constant UNIV3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    bytes32 constant UNIV3_INIT = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;

    address owner = makeAddr("owner");
    address team = makeAddr("team");
    address artist = makeAddr("artist");
    address attacker = makeAddr("attacker");
    address trader = makeAddr("trader");

    ArtCoinsFactory factory;
    FTMockHook hook;
    FTMockLocker locker;
    FTMockExtension ext;

    function setUp() public {
        factory = new ArtCoinsFactory(owner);
        hook = new FTMockHook();
        locker = new FTMockLocker();
        ext = new FTMockExtension();
        vm.startPrank(owner);
        factory.setTeamFeeRecipient(team);
        factory.setHook(address(hook), true);
        factory.setLocker(address(locker), address(hook), true);
        factory.setExtension(address(ext), true);
        // model a v2 factory that is open to the public (the live one is
        // deprecated, so every factory finding below is owner/admin only today)
        factory.setDeprecated(false);
        vm.stopPrank();
        vm.deal(artist, 10 ether);
        vm.deal(attacker, 10 ether);
    }

    // ─── helpers ─────────────────────────────────────────────────────────

    function _cfg(address admin, bytes32 salt)
        internal
        view
        returns (IArtCoinsFactory.DeploymentConfig memory dc)
    {
        dc.tokenConfig = IArtCoinsFactory.TokenConfig({
            tokenAdmin: admin,
            name: "Planned Coin",
            symbol: "PLAN",
            salt: salt,
            image: "ipfs://img",
            metadata: "desc",
            context: "ctx",
            totalSupply: 0,
            renderer: address(0)
        });
        dc.poolConfig = IArtCoinsFactory.PoolConfig({
            hook: address(hook),
            pairedToken: WETH,
            tickIfToken0IsArtCoins: -230_400,
            tickSpacing: 200,
            poolData: ""
        });
        dc.lockerConfig.locker = address(locker);
        dc.lockerConfig.rewardAdmins = new address[](1);
        dc.lockerConfig.rewardAdmins[0] = admin;
        dc.lockerConfig.rewardRecipients = new address[](1);
        dc.lockerConfig.rewardRecipients[0] = admin;
        dc.lockerConfig.rewardBps = new uint16[](1);
        dc.lockerConfig.rewardBps[0] = 8000; // + 2000 default protocol slot
        dc.lockerConfig.tickLower = new int24[](1);
        dc.lockerConfig.tickLower[0] = -230_400;
        dc.lockerConfig.tickUpper = new int24[](1);
        dc.lockerConfig.tickUpper[0] = 230_400;
        dc.lockerConfig.positionBps = new uint16[](1);
        dc.lockerConfig.positionBps[0] = 10_000;
    }

    function _taxCfg(address sink, uint16 bps) internal view returns (TaxConfig memory tc) {
        tc.enabled = true;
        tc.taxBps = bps;
        tc.taxBpsMax = 2000;
        tc.burnAddress = sink;
        tc.poolManager = PM;
        tc.canonicalHook = address(hook);
        tc.pairedToken = WETH;
        tc.canonicalPoolFee = DYN;
        tc.canonicalTickSpacing = 200;
        tc.venues = new TaxVenue[](2);
        tc.venues[0] = TaxVenue({
            kind: 1, factory: UNIV2_FACTORY, initCodeHash: UNIV2_INIT, counterToken: WETH, v3Fee: 0
        });
        tc.venues[1] = TaxVenue({
            kind: 2, factory: UNIV3_FACTORY, initCodeHash: UNIV3_INIT, counterToken: WETH, v3Fee: 3000
        });
    }

    function _v2(address tok, address counter) internal pure returns (address) {
        (address t0, address t1) = tok < counter ? (tok, counter) : (counter, tok);
        return address(uint160(uint256(keccak256(abi.encodePacked(
            hex"ff", UNIV2_FACTORY, keccak256(abi.encodePacked(t0, t1)), UNIV2_INIT
        )))));
    }

    function _v3(address tok, address counter, uint24 fee) internal pure returns (address) {
        (address t0, address t1) = tok < counter ? (tok, counter) : (counter, tok);
        return address(uint160(uint256(keccak256(abi.encodePacked(
            hex"ff", UNIV3_FACTORY, keccak256(abi.encode(t0, t1, fee)), UNIV3_INIT
        )))));
    }

    function _directTaxed(address sink, uint16 bps) internal returns (ArtCoinsToken t) {
        t = new ArtCoinsToken(
            "Taxed", "TAX", 1_000_000e18, artist, "", "", "", address(0), _taxCfg(sink, bps)
        );
    }

    // ─── FT-01 canonical exemption budget is not backed by a real outflow ──

    /// @notice the token accepts any hook attestation as a fungible, tx-wide
    ///         budget and burns it down on ANY venue outflow. the real hook
    ///         attests on every canonical `afterRemoveLiquidity` (and every
    ///         canonical buy) from the pool delta, not from a token transfer.
    ///         in v4 flash accounting an add(X) followed by remove(X) in one
    ///         unlock nets to ~0, so nothing ever leaves the pool manager for
    ///         the canonical pool, yet budget X is attested. the attestations
    ///         below model exactly those two removals (two positions, partial
    ///         sizes); the budget stacks and then exempts a side pool buy on
    ///         the same pool manager AND a v2 pair buy.
    function test_bug_FT01_unbackedCanonicalBudgetExemptsSideVenues() public {
        ArtCoinsToken t = _directTaxed(DEAD, 1500);
        bytes32 canon = t.canonicalPoolId();
        address v2pair = _v2(address(t), WETH);
        t.transfer(PM, 10_000e18);
        t.transfer(v2pair, 10_000e18);

        // baseline: a side pool buy (pool manager -> trader) pays 15%
        vm.prank(PM);
        t.transfer(trader, 1000e18);
        assertEq(t.balanceOf(trader), 850e18, "baseline taxed");

        // canonical add+remove on two positions, netted in flash accounting:
        // the hook attests the removal deltas, no PCT leaves the pool manager
        uint256 pmBefore = t.balanceOf(PM);
        vm.startPrank(address(hook));
        t.attestCanonicalBudget(canon, 1200e18); // position A (partial remove)
        t.attestCanonicalBudget(canon, 800e18); // position B
        vm.stopPrank();
        assertEq(t.balanceOf(PM), pmBefore, "no canonical outflow happened");

        // side v4 pool buy in the same tx: untaxed
        address buyer = makeAddr("buyer");
        vm.prank(PM);
        t.transfer(buyer, 1000e18);
        assertEq(t.balanceOf(buyer), 1000e18, "side v4 buy fully exempt");

        // v2 pair buy in the same tx: untaxed with the leftover budget
        address buyer2 = makeAddr("buyer2");
        vm.prank(v2pair);
        t.transfer(buyer2, 1000e18);
        assertEq(t.balanceOf(buyer2), 1000e18, "v2 buy fully exempt");

        // budget is now spent: the next side buy is taxed again
        address buyer3 = makeAddr("buyer3");
        vm.prank(PM);
        t.transfer(buyer3, 1000e18);
        assertEq(t.balanceOf(buyer3), 850e18, "taxed once budget is gone");
    }

    // ─── FT-02 launch hijack: create2 address ignores sender + pool config ─

    function test_bug_FT02_launchHijackSameAddressDifferentConfig() public {
        bytes32 salt = keccak256("artist planned salt");
        IArtCoinsFactory.DeploymentConfig memory planned = _cfg(artist, salt);

        // the address the artist announced, computed off chain
        TaxConfig memory none;
        bytes memory initCode = abi.encodePacked(
            type(ArtCoinsToken).creationCode,
            abi.encode(
                "Planned Coin",
                "PLAN",
                factory.DEFAULT_TOKEN_SUPPLY(),
                artist,
                "ipfs://img",
                "desc",
                "ctx",
                address(0),
                none
            )
        );
        address predicted = vm.computeCreate2Address(
            keccak256(abi.encode(artist, salt)), keccak256(initCode), address(factory)
        );

        // attacker copies tokenConfig only; everything else is theirs
        IArtCoinsFactory.DeploymentConfig memory evil = _cfg(artist, salt);
        evil.lockerConfig.rewardAdmins[0] = attacker;
        evil.lockerConfig.rewardRecipients[0] = attacker;
        evil.poolConfig.tickIfToken0IsArtCoins = 200_000; // absurd start price
        evil.poolConfig.tickSpacing = 60;
        evil.extensionConfigs = new IArtCoinsFactory.ExtensionConfig[](1);
        evil.extensionConfigs[0] = IArtCoinsFactory.ExtensionConfig({
            extension: address(ext), msgValue: 0, extensionBps: 9000, extensionData: ""
        });
        ext.setBeneficiary(attacker);

        vm.prank(attacker);
        address got = factory.deployToken{value: FEE}(evil);

        assertEq(got, predicted, "attacker landed on the planned address");
        assertEq(locker.recipients()[0], attacker, "lp rewards to attacker");
        assertEq(ArtCoinsToken(got).balanceOf(attacker), 900_000_000e18, "90% supply to attacker");
        assertEq(ArtCoinsToken(got).admin(), artist, "token admin is the only bound role");

        // the artist's real launch now reverts (create2 collision)
        vm.prank(artist);
        vm.expectRevert();
        factory.deployToken{value: FEE}(planned);
    }

    // ─── FT-03 protocol bps override is caller chosen (can be 0) ──────────

    function test_bug_FT03_publicCallerZeroesProtocolSlot() public {
        IArtCoinsFactory.DeploymentConfig memory dc = _cfg(attacker, bytes32("x"));
        dc.lockerConfig.rewardBps[0] = 10_000;

        // default path would force the 2000 bps protocol slot
        vm.prank(attacker);
        vm.expectRevert(IArtCoinsFactory.ProjectSideBpsMismatch.selector);
        factory.deployToken{value: FEE}(dc);

        // the override path lets any caller drop it entirely
        vm.prank(attacker);
        factory.deployTokenWithProtocolBps{value: FEE}(dc, 0);
        assertEq(locker.recipients().length, 1, "no protocol slot");
        assertEq(locker.bps()[0], 10_000, "project keeps 100% of lp fees");
    }

    // ─── FT-04 an allowlisted contract cannot be disabled once its erc165 fails

    function test_bug_FT04_cannotDisableExtensionWhoseInterfaceCheckFails() public {
        ext.setIface(false);
        vm.prank(owner);
        vm.expectRevert(IArtCoinsFactory.InvalidExtension.selector);
        factory.setExtension(address(ext), false);
        assertTrue(factory.enabledExtensions(address(ext)), "still enabled");
    }

    // ─── FT-05 coin is mutable after launch beyond the renderer ───────────

    function test_bug_FT05_tokenAdminMutatesMoreThanRenderer() public {
        ArtCoinsToken t = _directTaxed(DEAD, 1500);
        vm.startPrank(artist);
        t.updateImage("ipfs://swapped");
        t.updateMetadata("rewritten");
        t.setTaxBps(2000);
        vm.stopPrank();
        assertEq(t.imageUrl(), "ipfs://swapped");
        assertEq(t.metadata(), "rewritten");
        assertEq(t.taxBps(), 2000, "tax raised to the cap post launch");
    }

    // ─── FT-06 tax config is not bound to the pool the factory creates ────

    function test_bug_FT06_taxCanonicalPoolNotBoundToFactoryPool() public {
        IArtCoinsFactory.DeploymentConfig memory dc = _cfg(artist, bytes32("tax"));
        dc.poolConfig.tickSpacing = 60; // tax config says 200
        TaxConfig memory tc = _taxCfg(DEAD, 1500);

        vm.prank(owner); // the and-tax path is what 111 used; owner can always call
        address tok = factory.deployTokenWithProtocolBpsAndTax{value: FEE}(dc, 2000, tc);

        assertTrue(
            ArtCoinsToken(tok).canonicalPoolId() != hook.lastKeyId(),
            "factory pool is not the token's canonical pool"
        );
        // so every buy from the launch pool is taxed and every lp exit too
        assertTrue(ArtCoinsToken(tok).isTaxVenue(PM));
    }

    // ─── FT-07 tax sink and exempt list are arbitrary, deployer controlled ─

    function test_bug_FT07_publicDeployerRoutesTaxToSelfAndExemptsSelf() public {
        IArtCoinsFactory.DeploymentConfig memory dc = _cfg(attacker, bytes32("rug"));
        TaxConfig memory tc = _taxCfg(attacker, 2000); // "burn" sink = attacker
        tc.exempt = new address[](1);
        tc.exempt[0] = attacker;

        vm.prank(attacker);
        address tok = factory.deployTokenWithProtocolBpsAndTax{value: FEE}(dc, 2000, tc);
        ArtCoinsToken t = ArtCoinsToken(tok);
        assertEq(t.taxBurnAddress(), attacker);

        deal(tok, PM, 1000e18);
        vm.prank(PM);
        t.transfer(trader, 1000e18);
        assertEq(t.balanceOf(trader), 800e18, "buyer pays 20%");
        assertEq(t.balanceOf(attacker), 200e18, "deployer collects the 'burn'");

        deal(tok, PM, 1000e18);
        vm.prank(PM);
        t.transfer(attacker, 1000e18);
        assertEq(t.balanceOf(attacker), 1200e18, "deployer buys tax free");
    }

    // ─── FT-08 venue set is frozen and only covers listed tuples ──────────

    function test_bug_FT08_unlistedVenuesAreUntaxed() public {
        ArtCoinsToken t = _directTaxed(DEAD, 1500);
        address v3OnePct = _v3(address(t), WETH, 10_000); // only 3000 listed
        address v2Usdc = _v2(address(t), USDC); // only WETH listed
        assertFalse(t.isTaxVenue(v3OnePct));
        assertFalse(t.isTaxVenue(v2Usdc));

        t.transfer(v3OnePct, 1000e18);
        vm.prank(v3OnePct);
        t.transfer(trader, 1000e18);
        assertEq(t.balanceOf(trader), 1000e18, "side pool at another tier: no tax");

        // rounding: a venue outflow below 10_000 / bps wei pays zero
        address dust = makeAddr("dust");
        t.transfer(PM, 6);
        vm.prank(PM);
        t.transfer(dust, 6);
        assertEq(t.balanceOf(dust), 6, "dust buy untaxed");
    }

    // ─── FT-09 extension rounding dust stays in the factory ───────────────

    function test_bug_FT09_extensionRoundingDustSweptToTeam() public {
        IArtCoinsFactory.DeploymentConfig memory dc = _cfg(artist, bytes32("dust"));
        dc.tokenConfig.totalSupply = 1e18 + 9999;
        dc.extensionConfigs = new IArtCoinsFactory.ExtensionConfig[](2);
        dc.extensionConfigs[0] = IArtCoinsFactory.ExtensionConfig(address(ext), 0, 1, "");
        dc.extensionConfigs[1] = IArtCoinsFactory.ExtensionConfig(address(ext), 0, 1, "");

        vm.prank(artist);
        address tok = factory.deployToken{value: FEE}(dc);
        assertEq(ArtCoinsToken(tok).balanceOf(address(factory)), 1, "1 wei stranded");

        vm.prank(owner);
        factory.claimTeamFees(tok);
        assertEq(ArtCoinsToken(tok).balanceOf(team), 1);
    }

    // ─── FT-10 protocol slot silently drops extra recipients ──────────────

    function test_bug_FT10_mismatchedRewardArraysTruncatedByInjection() public {
        IArtCoinsFactory.DeploymentConfig memory dc = _cfg(artist, bytes32("arr"));
        address collaborator = makeAddr("collaborator");
        dc.lockerConfig.rewardAdmins = new address[](2);
        dc.lockerConfig.rewardAdmins[0] = artist;
        dc.lockerConfig.rewardAdmins[1] = collaborator;
        dc.lockerConfig.rewardRecipients = new address[](2);
        dc.lockerConfig.rewardRecipients[0] = artist;
        dc.lockerConfig.rewardRecipients[1] = collaborator;
        // bps array forgot the collaborator; factory does not check lengths

        vm.prank(artist);
        factory.deployToken{value: FEE}(dc);
        address[] memory r = locker.recipients();
        assertEq(r.length, 2);
        assertEq(r[0], artist);
        assertEq(r[1], team, "collaborator overwritten by the protocol slot");
    }

    // ─── FT-11 escrow: anyone can force push an erc20 balance ─────────────

    function test_bug_FT11_escrowForcedClaimStrandsErc20InFeeOwner() public {
        ArtCoinsFeeEscrow escrow = new ArtCoinsFeeEscrow(owner);
        address depositor = makeAddr("depositor");
        vm.prank(owner);
        escrow.addDepositor(depositor);

        ArtCoinsToken coin = _directTaxed(DEAD, 0);
        FTEscrowFeeOwner feeOwner = new FTEscrowFeeOwner();
        coin.transfer(depositor, 100e18);
        vm.startPrank(depositor);
        coin.approve(address(escrow), 100e18);
        escrow.storeFees(address(feeOwner), address(coin), 100e18);
        vm.stopPrank();

        // griefer pushes before the owner can redirect
        vm.prank(attacker);
        escrow.claim(address(feeOwner), address(coin));
        assertEq(coin.balanceOf(address(feeOwner)), 100e18, "stranded in fee owner");

        vm.expectRevert(IArtCoinsFeeLocker.NoFeesToClaim.selector);
        feeOwner.redirect(address(escrow), address(coin), payable(artist));
    }

    // ─── holds ────────────────────────────────────────────────────────────

    /// @notice deploy fee is an exact match (no refund path needed), is
    ///         forwarded to `teamFeeRecipient`, and extension eth is isolated.
    function test_holds_deployFeeExactAndExtensionEthIsolated() public {
        IArtCoinsFactory.DeploymentConfig memory dc = _cfg(artist, bytes32("fee"));
        vm.startPrank(artist);
        vm.expectRevert(IArtCoinsFactory.ExtensionMsgValueMismatch.selector);
        factory.deployToken{value: FEE + 1}(dc);
        vm.expectRevert(IArtCoinsFactory.ExtensionMsgValueMismatch.selector);
        factory.deployToken{value: FEE - 1}(dc);
        vm.stopPrank();

        // stray eth on the factory cannot be spent by a deployer
        vm.deal(address(factory), 1 ether);
        FTMockExtension ext2 = new FTMockExtension();
        vm.prank(owner);
        factory.setExtension(address(ext2), true);
        dc.extensionConfigs = new IArtCoinsFactory.ExtensionConfig[](2);
        dc.extensionConfigs[0] = IArtCoinsFactory.ExtensionConfig(address(ext), 0.1 ether, 0, "");
        dc.extensionConfigs[1] = IArtCoinsFactory.ExtensionConfig(address(ext2), 0.2 ether, 0, "");
        uint256 teamBefore = team.balance;
        vm.prank(artist);
        factory.deployToken{value: FEE + 0.3 ether}(dc);
        assertEq(team.balance - teamBefore, FEE);
        assertEq(ext.ethReceived(), 0.1 ether);
        assertEq(ext2.ethReceived(), 0.2 ether);
        assertEq(address(factory).balance, 1 ether, "factory balance untouched");
    }

    /// @notice deprecated gating: public callers blocked, owner and admins pass.
    function test_holds_deprecatedGate() public {
        vm.prank(owner);
        factory.setDeprecated(true);
        vm.prank(attacker);
        vm.expectRevert(IArtCoinsFactory.Deprecated.selector);
        factory.deployToken{value: FEE}(_cfg(attacker, bytes32("d")));
        vm.prank(owner);
        factory.setAdmin(attacker, true);
        vm.prank(attacker);
        factory.deployToken{value: FEE}(_cfg(attacker, bytes32("d")));
    }

    /// @notice contractURI escapes quotes / backslashes in name, description, image.
    function test_holds_contractUriEscapesJson() public {
        ArtCoinsToken t = new ArtCoinsToken(
            'a"b', "S\\", 1e18, artist, '","x":"', "line\nbreak", "", address(0), _noTax()
        );
        string memory uri = t.contractURI();
        assertGt(bytes(uri).length, 29);
        string memory expected = string.concat(
            "data:application/json;base64,",
            vm.toBase64(
                bytes(
                    '{"name":"a\\"b","symbol":"S\\\\","description":"line\\nbreak","image":"\\",\\"x\\":\\""}'
                )
            )
        );
        assertEq(uri, expected);
    }

    function _noTax() internal pure returns (TaxConfig memory tc) {}
}
