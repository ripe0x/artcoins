// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Test, console2} from "forge-std/Test.sol";

import {ArtCoinsAirdrop} from "../src/extensions/ArtCoinsAirdrop.sol";
import {IArtCoinsAirdrop} from "../src/extensions/interfaces/IArtCoinsAirdrop.sol";
import {IArtCoinsExtension} from "../src/interfaces/IArtCoinsExtension.sol";
import {IArtCoinsFactory} from "../src/interfaces/IArtCoinsFactory.sol";

/// @notice Unit tests for ArtCoinsAirdrop — covering setup, claim happy and
///         revert paths, vesting math, root updates, admin sweep, and the
///         lockup floor relaxation (MIN_LOCKUP_DURATION = 0).
///
/// @dev    The contract has a single privileged caller (`factory`). To exercise
///         it without spinning up the full factory + Uniswap v4 stack, the
///         tests use this contract as the factory by deploying the airdrop
///         with `factory_ = address(this)`. We then call `receiveTokens`
///         directly with a hand-built DeploymentConfig.
contract ArtCoinsAirdropTest is Test {
    ArtCoinsAirdrop internal airdrop;
    ERC20Mock internal token;

    // Test actors
    address internal admin = makeAddr("admin");
    address internal alice;
    address internal bob;
    address internal carol;
    address internal dan;
    uint256 internal aliceAmt = 100 ether;
    uint256 internal bobAmt = 250 ether;
    uint256 internal carolAmt = 42 ether;
    uint256 internal danAmt = 7 ether;
    uint256 internal totalAllocated; // sum of the 4

    // Tree state computed in setUp
    bytes32 internal root;
    bytes32[] internal aliceProof;
    bytes32[] internal bobProof;
    bytes32[] internal carolProof;
    bytes32[] internal danProof;

    // Default lifecycle params
    uint256 internal constant LOCKUP = 1 days;
    uint256 internal constant VESTING = 30 days;
    uint256 internal constant TOTAL_SUPPLY = 1000 ether;

    function setUp() public {
        // Deterministic addresses — sort matters because the merkle helper
        // pair-hashes leaves in tree order, not sorted order. We pick fixed
        // values so the proofs are stable across runs.
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        dan = makeAddr("dan");
        totalAllocated = aliceAmt + bobAmt + carolAmt + danAmt;

        airdrop = new ArtCoinsAirdrop(address(this));
        token = new ERC20Mock();
        token.mint(address(this), TOTAL_SUPPLY);

        // Build a 4-leaf merkle tree.
        bytes32 lA = _leaf(alice, aliceAmt);
        bytes32 lB = _leaf(bob, bobAmt);
        bytes32 lC = _leaf(carol, carolAmt);
        bytes32 lD = _leaf(dan, danAmt);

        bytes32 pAB = _commHash(lA, lB);
        bytes32 pCD = _commHash(lC, lD);
        root = _commHash(pAB, pCD);

        aliceProof = new bytes32[](2);
        aliceProof[0] = lB;
        aliceProof[1] = pCD;

        bobProof = new bytes32[](2);
        bobProof[0] = lA;
        bobProof[1] = pCD;

        carolProof = new bytes32[](2);
        carolProof[0] = lD;
        carolProof[1] = pAB;

        danProof = new bytes32[](2);
        danProof[0] = lC;
        danProof[1] = pAB;
    }

    // ─── Helpers ────────────────────────────────────────────────────────

    function _leaf(address a, uint256 amt) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(a, amt))));
    }

    function _commHash(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    function _emptyPoolKey() internal pure returns (PoolKey memory pk) {}

    function _depConfig(
        address admin_,
        bytes32 root_,
        uint256 lockupDur,
        uint256 vestingDur,
        uint16 bps
    ) internal view returns (IArtCoinsFactory.DeploymentConfig memory cfg) {
        cfg.extensionConfigs = new IArtCoinsFactory.ExtensionConfig[](1);
        cfg.extensionConfigs[0] = IArtCoinsFactory.ExtensionConfig({
            extension: address(airdrop),
            msgValue: 0,
            extensionBps: bps,
            extensionData: abi.encode(
                IArtCoinsAirdrop.AirdropV2ExtensionData({
                    admin: admin_,
                    merkleRoot: root_,
                    lockupDuration: lockupDur,
                    vestingDuration: vestingDur
                })
            )
        });
    }

    function _setupAirdrop(uint256 lockupDur, uint256 vestingDur) internal {
        token.approve(address(airdrop), TOTAL_SUPPLY);
        airdrop.receiveTokens(
            _depConfig(admin, root, lockupDur, vestingDur, 1000),
            _emptyPoolKey(),
            address(token),
            TOTAL_SUPPLY,
            0
        );
    }

    // ─── receiveTokens ─────────────────────────────────────────────────

    function test_receiveTokens_setsState() public {
        _setupAirdrop(LOCKUP, VESTING);
        (
            address admin_,
            bytes32 root_,
            uint256 totalSupply_,
            uint256 totalClaimed_,
            uint256 lockupEnd_,
            uint256 vestingEnd_,
            uint256 adminClaimTime_,
            bool adminClaimed_
        ) = airdrop.airdrops(address(token));

        assertEq(admin_, admin);
        assertEq(root_, root);
        assertEq(totalSupply_, TOTAL_SUPPLY);
        assertEq(totalClaimed_, 0);
        assertEq(lockupEnd_, block.timestamp + LOCKUP);
        assertEq(vestingEnd_, block.timestamp + LOCKUP + VESTING);
        assertEq(adminClaimTime_, block.timestamp + LOCKUP + VESTING + 14 days);
        assertFalse(adminClaimed_);
        assertEq(token.balanceOf(address(airdrop)), TOTAL_SUPPLY);
    }

    function test_receiveTokens_revertsForNonFactory() public {
        token.approve(address(airdrop), TOTAL_SUPPLY);
        vm.prank(makeAddr("notFactory"));
        vm.expectRevert(IArtCoinsAirdrop.Unauthorized.selector);
        airdrop.receiveTokens(
            _depConfig(admin, root, LOCKUP, VESTING, 1000),
            _emptyPoolKey(),
            address(token),
            TOTAL_SUPPLY,
            0
        );
    }

    function test_receiveTokens_revertsIfAlreadyExists() public {
        _setupAirdrop(LOCKUP, VESTING);
        token.mint(address(this), TOTAL_SUPPLY);
        token.approve(address(airdrop), TOTAL_SUPPLY);
        vm.expectRevert(IArtCoinsAirdrop.AirdropAlreadyExists.selector);
        airdrop.receiveTokens(
            _depConfig(admin, root, LOCKUP, VESTING, 1000),
            _emptyPoolKey(),
            address(token),
            TOTAL_SUPPLY,
            0
        );
    }

    function test_receiveTokens_revertsIfBpsZero() public {
        token.approve(address(airdrop), TOTAL_SUPPLY);
        vm.expectRevert(IArtCoinsAirdrop.InvalidAirdropPercentage.selector);
        airdrop.receiveTokens(
            _depConfig(admin, root, LOCKUP, VESTING, 0),
            _emptyPoolKey(),
            address(token),
            TOTAL_SUPPLY,
            0
        );
    }

    function test_receiveTokens_revertsIfMsgValueNonZero() public {
        token.approve(address(airdrop), TOTAL_SUPPLY);
        IArtCoinsFactory.DeploymentConfig memory cfg =
            _depConfig(admin, root, LOCKUP, VESTING, 1000);
        cfg.extensionConfigs[0].msgValue = 1;
        vm.deal(address(this), 1);
        vm.expectRevert(IArtCoinsExtension.InvalidMsgValue.selector);
        airdrop.receiveTokens{value: 1}(cfg, _emptyPoolKey(), address(token), TOTAL_SUPPLY, 0);
    }

    /// @notice The PR change: lockupDuration = 0 is now allowed (was rejected
    ///         with AirdropLockupDurationTooShort previously).
    function test_receiveTokens_acceptsZeroLockup() public {
        _setupAirdrop(0, 0);
        (,,,, uint256 lockupEnd_, uint256 vestingEnd_,,) = airdrop.airdrops(address(token));
        assertEq(lockupEnd_, block.timestamp);
        assertEq(vestingEnd_, block.timestamp);
    }

    // ─── claim — happy paths ───────────────────────────────────────────

    function test_claim_atVestingEnd_paysFullAllocation() public {
        _setupAirdrop(LOCKUP, VESTING);
        vm.warp(block.timestamp + LOCKUP + VESTING);

        vm.prank(alice);
        airdrop.claim(address(token), alice, aliceAmt, aliceProof);
        assertEq(token.balanceOf(alice), aliceAmt);
    }

    function test_claim_zeroVesting_paysFullAtLockupEnd() public {
        _setupAirdrop(LOCKUP, 0);
        vm.warp(block.timestamp + LOCKUP);

        vm.prank(bob);
        airdrop.claim(address(token), bob, bobAmt, bobProof);
        assertEq(token.balanceOf(bob), bobAmt);
    }

    function test_claim_zeroLockupZeroVesting_paysFullNextSecond() public {
        _setupAirdrop(0, 0);
        vm.warp(block.timestamp + 1);

        vm.prank(carol);
        airdrop.claim(address(token), carol, carolAmt, carolProof);
        assertEq(token.balanceOf(carol), carolAmt);
    }

    function test_claim_halfwayThroughVesting_paysHalf() public {
        _setupAirdrop(LOCKUP, VESTING);
        vm.warp(block.timestamp + LOCKUP + VESTING / 2);

        vm.prank(alice);
        airdrop.claim(address(token), alice, aliceAmt, aliceProof);
        // Linear interpolation: should be ~50% (allow ±1 wei for integer math)
        assertApproxEqAbs(token.balanceOf(alice), aliceAmt / 2, 1);
    }

    function test_claim_multiplePartialClaims_accumulate() public {
        _setupAirdrop(LOCKUP, VESTING);
        vm.warp(block.timestamp + LOCKUP + VESTING / 4);
        vm.prank(alice);
        airdrop.claim(address(token), alice, aliceAmt, aliceProof);
        uint256 first = token.balanceOf(alice);
        assertGt(first, 0);
        assertLt(first, aliceAmt);

        vm.warp(block.timestamp + VESTING / 4);
        vm.prank(alice);
        airdrop.claim(address(token), alice, aliceAmt, aliceProof);
        uint256 second = token.balanceOf(alice);
        assertGt(second, first);

        vm.warp(block.timestamp + VESTING); // past end
        vm.prank(alice);
        airdrop.claim(address(token), alice, aliceAmt, aliceProof);
        assertEq(token.balanceOf(alice), aliceAmt);
    }

    function test_claim_emitsEvent() public {
        _setupAirdrop(LOCKUP, 0);
        vm.warp(block.timestamp + LOCKUP);
        vm.expectEmit(true, true, false, true, address(airdrop));
        emit IArtCoinsAirdrop.AirdropClaimed(address(token), alice, aliceAmt, 0);
        vm.prank(alice);
        airdrop.claim(address(token), alice, aliceAmt, aliceProof);
    }

    function test_claim_updatesTotalClaimed() public {
        _setupAirdrop(LOCKUP, 0);
        vm.warp(block.timestamp + LOCKUP);
        vm.prank(alice);
        airdrop.claim(address(token), alice, aliceAmt, aliceProof);
        vm.prank(bob);
        airdrop.claim(address(token), bob, bobAmt, bobProof);
        (,,, uint256 totalClaimed_,,,,) = airdrop.airdrops(address(token));
        assertEq(totalClaimed_, aliceAmt + bobAmt);
    }

    function test_claim_anyoneCanClaimForRecipient() public {
        // The contract identifies the recipient by the leaf, not msg.sender.
        // A relayer (or anyone) can submit the proof — tokens go to `recipient`.
        _setupAirdrop(LOCKUP, 0);
        vm.warp(block.timestamp + LOCKUP);
        vm.prank(makeAddr("relayer"));
        airdrop.claim(address(token), alice, aliceAmt, aliceProof);
        assertEq(token.balanceOf(alice), aliceAmt);
    }

    // ─── claim — revert paths ─────────────────────────────────────────

    function test_claim_revertsIfBeforeLockup() public {
        _setupAirdrop(LOCKUP, VESTING);
        // still in lockup
        vm.expectRevert(IArtCoinsAirdrop.AirdropNotUnlocked.selector);
        vm.prank(alice);
        airdrop.claim(address(token), alice, aliceAmt, aliceProof);
    }

    function test_claim_revertsOnInvalidProof_wrongAmount() public {
        _setupAirdrop(LOCKUP, 0);
        vm.warp(block.timestamp + LOCKUP);
        vm.expectRevert(IArtCoinsAirdrop.InvalidProof.selector);
        vm.prank(alice);
        airdrop.claim(address(token), alice, aliceAmt + 1, aliceProof);
    }

    function test_claim_revertsOnInvalidProof_wrongRecipient() public {
        _setupAirdrop(LOCKUP, 0);
        vm.warp(block.timestamp + LOCKUP);
        // bob's proof, alice's address — fails
        vm.expectRevert(IArtCoinsAirdrop.InvalidProof.selector);
        vm.prank(alice);
        airdrop.claim(address(token), alice, bobAmt, bobProof);
    }

    function test_claim_revertsOnInvalidProof_outsider() public {
        _setupAirdrop(LOCKUP, 0);
        vm.warp(block.timestamp + LOCKUP);
        address outsider = makeAddr("outsider");
        vm.expectRevert(IArtCoinsAirdrop.InvalidProof.selector);
        vm.prank(outsider);
        airdrop.claim(address(token), outsider, 1 ether, aliceProof);
    }

    function test_claim_revertsOnZeroAllocated() public {
        _setupAirdrop(LOCKUP, 0);
        vm.warp(block.timestamp + LOCKUP);
        vm.expectRevert(IArtCoinsAirdrop.ZeroClaim.selector);
        vm.prank(alice);
        airdrop.claim(address(token), alice, 0, aliceProof);
    }

    function test_claim_revertsIfAlreadyFullyClaimed() public {
        _setupAirdrop(LOCKUP, 0);
        vm.warp(block.timestamp + LOCKUP);
        vm.prank(alice);
        airdrop.claim(address(token), alice, aliceAmt, aliceProof);
        // Second attempt should revert with UserMaxClaimed
        vm.expectRevert(IArtCoinsAirdrop.UserMaxClaimed.selector);
        vm.prank(alice);
        airdrop.claim(address(token), alice, aliceAmt, aliceProof);
    }

    function test_claim_revertsWithZeroToClaim_betweenVestingTicks() public {
        // With a small allocation and a long vesting period, two claims within
        // a single second produce 0 newly-vested wei → ZeroToClaim.
        // We use a 1-wei allocation and ~very large duration so the first
        // claim grabs the only bit and subsequent ticks vest nothing new.
        // Easiest reproducer: claim twice at the same timestamp with vesting.
        _setupAirdrop(LOCKUP, VESTING);
        vm.warp(block.timestamp + LOCKUP + 1); // just past lockup, tiny amount vested
        vm.prank(alice);
        airdrop.claim(address(token), alice, aliceAmt, aliceProof);
        // No further time passed: nothing new to claim
        vm.expectRevert(IArtCoinsAirdrop.ZeroToClaim.selector);
        vm.prank(alice);
        airdrop.claim(address(token), alice, aliceAmt, aliceProof);
    }

    function test_claim_revertsIfTokenHasNoAirdrop() public {
        ERC20Mock other = new ERC20Mock();
        vm.expectRevert(IArtCoinsAirdrop.AirdropNotCreated.selector);
        vm.prank(alice);
        airdrop.claim(address(other), alice, aliceAmt, aliceProof);
    }

    // ─── updateMerkleRoot ─────────────────────────────────────────────

    function test_updateMerkleRoot_revertsForNonAdmin() public {
        _setupAirdrop(LOCKUP, VESTING);
        vm.warp(block.timestamp + LOCKUP + 1 days + 1);
        vm.expectRevert(IArtCoinsAirdrop.Unauthorized.selector);
        vm.prank(alice);
        airdrop.updateMerkleRoot(address(token), bytes32(uint256(1)));
    }

    function test_updateMerkleRoot_revertsBeforeWindowOpens() public {
        _setupAirdrop(LOCKUP, VESTING);
        // During lockup — ZERO_CLAIM_OVERWRITE_INTERVAL not yet passed
        vm.expectRevert(IArtCoinsAirdrop.UpdateMerkleRootNotAllowed.selector);
        vm.prank(admin);
        airdrop.updateMerkleRoot(address(token), bytes32(uint256(1)));
    }

    function test_updateMerkleRoot_succeedsAfterWindowOpens() public {
        _setupAirdrop(LOCKUP, VESTING);
        vm.warp(block.timestamp + LOCKUP + 1 days + 1);
        bytes32 newRoot = bytes32(uint256(0xCAFE));
        vm.prank(admin);
        airdrop.updateMerkleRoot(address(token), newRoot);
        (, bytes32 root_,,,,,,) = airdrop.airdrops(address(token));
        assertEq(root_, newRoot);
    }

    function test_updateMerkleRoot_revertsAfterFirstClaim() public {
        _setupAirdrop(LOCKUP, 0);
        vm.warp(block.timestamp + LOCKUP);
        vm.prank(alice);
        airdrop.claim(address(token), alice, aliceAmt, aliceProof);

        // ZERO_CLAIM_OVERWRITE_INTERVAL has now passed (lockup ended at LOCKUP,
        // we're already past lockup + 0 since warp was exactly to lockup; warp
        // forward to ensure the interval check would otherwise pass).
        vm.warp(block.timestamp + 2 days);

        vm.expectRevert(IArtCoinsAirdrop.AirdropClaimsOccurred.selector);
        vm.prank(admin);
        airdrop.updateMerkleRoot(address(token), bytes32(uint256(0xCAFE)));
    }

    // ─── updateAdmin ──────────────────────────────────────────────────

    function test_updateAdmin_byAdmin_works() public {
        _setupAirdrop(LOCKUP, VESTING);
        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        airdrop.updateAdmin(address(token), newAdmin);
        (address admin_,,,,,,,) = airdrop.airdrops(address(token));
        assertEq(admin_, newAdmin);
    }

    function test_updateAdmin_byNonAdmin_reverts() public {
        _setupAirdrop(LOCKUP, VESTING);
        vm.expectRevert(IArtCoinsAirdrop.Unauthorized.selector);
        vm.prank(makeAddr("attacker"));
        airdrop.updateAdmin(address(token), makeAddr("evil"));
    }

    function test_updateAdmin_toZero_disablesAdminFunctions() public {
        _setupAirdrop(LOCKUP, VESTING);
        vm.prank(admin);
        airdrop.updateAdmin(address(token), address(0));
        // Now both updateMerkleRoot and adminClaim are unreachable: there's
        // no msg.sender == address(0) tx, so the modifier always reverts.
        vm.warp(block.timestamp + LOCKUP + 1 days + 1);
        vm.expectRevert(IArtCoinsAirdrop.Unauthorized.selector);
        vm.prank(admin); // old admin
        airdrop.updateMerkleRoot(address(token), bytes32(uint256(1)));
    }

    // ─── adminClaim (sweep) ───────────────────────────────────────────

    function test_adminClaim_revertsBeforeAdminClaimTime() public {
        _setupAirdrop(LOCKUP, VESTING);
        vm.expectRevert(IArtCoinsAirdrop.ClaimNotEnded.selector);
        vm.prank(admin);
        airdrop.adminClaim(address(token), admin);
    }

    function test_adminClaim_byNonAdmin_reverts() public {
        _setupAirdrop(LOCKUP, VESTING);
        vm.warp(block.timestamp + LOCKUP + VESTING + 14 days + 1);
        vm.expectRevert(IArtCoinsAirdrop.Unauthorized.selector);
        vm.prank(makeAddr("attacker"));
        airdrop.adminClaim(address(token), admin);
    }

    function test_adminClaim_sweepsRemainder() public {
        _setupAirdrop(LOCKUP, 0);
        vm.warp(block.timestamp + LOCKUP);
        // Alice claims her share first; the rest will be swept.
        vm.prank(alice);
        airdrop.claim(address(token), alice, aliceAmt, aliceProof);

        vm.warp(block.timestamp + 14 days + 1);
        uint256 expected = TOTAL_SUPPLY - aliceAmt;
        address recipient = makeAddr("sweepDst");
        vm.prank(admin);
        airdrop.adminClaim(address(token), recipient);
        assertEq(token.balanceOf(recipient), expected);
        (,,,,,,, bool adminClaimed_) = airdrop.airdrops(address(token));
        assertTrue(adminClaimed_);
    }

    function test_adminClaim_revertsIfAlreadySwept() public {
        _setupAirdrop(LOCKUP, VESTING);
        vm.warp(block.timestamp + LOCKUP + VESTING + 14 days + 1);
        vm.prank(admin);
        airdrop.adminClaim(address(token), admin);
        vm.expectRevert(IArtCoinsAirdrop.AdminClaimed.selector);
        vm.prank(admin);
        airdrop.adminClaim(address(token), admin);
    }

    function test_claim_revertsAfterAdminSwept() public {
        _setupAirdrop(LOCKUP, VESTING);
        vm.warp(block.timestamp + LOCKUP + VESTING + 14 days + 1);
        vm.prank(admin);
        airdrop.adminClaim(address(token), admin);

        vm.expectRevert(IArtCoinsAirdrop.AdminClaimed.selector);
        vm.prank(alice);
        airdrop.claim(address(token), alice, aliceAmt, aliceProof);
    }

    // ─── Total-supply cap edge case ───────────────────────────────────

    function test_claim_lastClaimerCappedToRemaining() public {
        // Set up an airdrop whose `totalSupply` (escrowed amount) is smaller
        // than the leaf sum, so the last claim is throttled.
        token.approve(address(airdrop), totalAllocated - 1); // one wei short
        airdrop.receiveTokens(
            _depConfig(admin, root, LOCKUP, 0, 1000),
            _emptyPoolKey(),
            address(token),
            totalAllocated - 1, // escrowed
            0
        );
        vm.warp(block.timestamp + LOCKUP);

        vm.prank(alice);
        airdrop.claim(address(token), alice, aliceAmt, aliceProof);
        vm.prank(bob);
        airdrop.claim(address(token), bob, bobAmt, bobProof);
        vm.prank(carol);
        airdrop.claim(address(token), carol, carolAmt, carolProof);
        // Dan tries to claim 7 ether but escrow only has 7 - 1 = 6.999...
        vm.prank(dan);
        airdrop.claim(address(token), dan, danAmt, danProof);
        assertEq(token.balanceOf(dan), danAmt - 1);

        // Subsequent claim attempt by dan reverts (fully drained).
        vm.expectRevert(IArtCoinsAirdrop.TotalMaxClaimed.selector);
        vm.prank(dan);
        airdrop.claim(address(token), dan, danAmt, danProof);
    }

    // ─── ERC-165 ──────────────────────────────────────────────────────

    function test_supportsInterface() public view {
        assertTrue(airdrop.supportsInterface(type(IArtCoinsExtension).interfaceId));
        assertFalse(airdrop.supportsInterface(0xdeadbeef));
    }
}
