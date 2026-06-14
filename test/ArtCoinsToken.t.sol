// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Test} from "forge-std/Test.sol";

import {ERC20 as SoladyERC20} from "solady/tokens/ERC20.sol";

import {ArtCoinsToken} from "../src/ArtCoinsToken.sol";
import {TaxConfig} from "../src/interfaces/IArtCoinsTaxable.sol";
import {IMetadataRenderer} from "../src/interfaces/IMetadataRenderer.sol";
import {DefaultMetadataRenderer} from "../src/renderer/DefaultMetadataRenderer.sol";

/// @dev Dormant (default-off) tax config — the token behaves exactly like a
///      vanilla ERC20. Used by unit tests that don't exercise the tax.
function _emptyTax() pure returns (TaxConfig memory t) {}

contract MockRenderer is IMetadataRenderer {
    string public constant MOCK_URI = "data:application/json;base64,eyJuYW1lIjoibW9jayJ9";

    function contractURI(address) external pure override returns (string memory) {
        return MOCK_URI;
    }
}

contract ArtCoinsTokenTest is Test {
    ArtCoinsToken public token;
    address public admin = address(0xA1);
    address public user1 = address(0xB1);
    address public user2 = address(0xB2);

    /// @notice Canonical Permit2 address — Solady's `_PERMIT2`.
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    uint256 constant SUPPLY = 100_000_000_000e18;
    string constant NAME = "TestToken";
    string constant SYMBOL = "TT";
    string constant IMAGE = "https://example.com/image.png";
    string constant METADATA = "A test token";
    string constant CONTEXT = "test context";

    function setUp() public {
        token = new ArtCoinsToken(
            NAME, SYMBOL, SUPPLY, admin, IMAGE, METADATA, CONTEXT, address(0), _emptyTax()
        );
    }

    // ─── Construction ──────────────────────────────────────────────────

    function test_construction() public view {
        assertEq(token.name(), NAME);
        assertEq(token.symbol(), SYMBOL);
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.admin(), admin);
        assertEq(token.originalAdmin(), admin);
        assertEq(token.imageUrl(), IMAGE);
        assertEq(token.metadata(), METADATA);
        assertEq(token.context(), CONTEXT);
        assertEq(token.metadataRenderer(), address(0));
        assertFalse(token.isVerified());
    }

    function test_constructWithRenderer_setsRendererAtomically() public {
        MockRenderer mock = new MockRenderer();
        ArtCoinsToken t = new ArtCoinsToken(
            NAME, SYMBOL, SUPPLY, admin, IMAGE, METADATA, CONTEXT, address(mock), _emptyTax()
        );

        // Renderer is wired up immediately — no second tx required.
        assertEq(t.metadataRenderer(), address(mock));
        assertEq(t.contractURI(), mock.MOCK_URI());
        assertEq(t.tokenURI(), mock.MOCK_URI());

        // Admin can still swap the renderer post-deploy.
        MockRenderer mock2 = new MockRenderer();
        vm.prank(admin);
        t.setMetadataRenderer(address(mock2));
        assertEq(t.metadataRenderer(), address(mock2));

        // And clearing it falls back to the built-in default URI.
        vm.prank(admin);
        t.setMetadataRenderer(address(0));
        assertEq(t.metadataRenderer(), address(0));
        assertTrue(_startsWith(t.contractURI(), "data:application/json;base64,"));
    }

    function test_constructRevertsOnZeroAdmin() public {
        vm.expectRevert(ArtCoinsToken.ZeroAddress.selector);
        new ArtCoinsToken(
            NAME, SYMBOL, SUPPLY, address(0), IMAGE, METADATA, CONTEXT, address(0), _emptyTax()
        );
    }

    function test_constructRevertsOnEoaRenderer() public {
        // user1 (0xB1) has no contract code → InvalidRenderer.
        vm.expectRevert(ArtCoinsToken.InvalidRenderer.selector);
        new ArtCoinsToken(NAME, SYMBOL, SUPPLY, admin, IMAGE, METADATA, CONTEXT, user1, _emptyTax());
    }

    // ─── Admin functions ────────────────────────────────────────────────

    function test_updateAdmin() public {
        vm.prank(admin);
        token.updateAdmin(user1);
        assertEq(token.admin(), user1);
        assertEq(token.originalAdmin(), admin); // unchanged
    }

    function test_updateAdminRevertsIfNotAdmin() public {
        vm.prank(user1);
        vm.expectRevert(ArtCoinsToken.NotAdmin.selector);
        token.updateAdmin(user1);
    }

    function test_updateAdminRevertsOnZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(ArtCoinsToken.ZeroAddress.selector);
        token.updateAdmin(address(0));
        assertEq(token.admin(), admin);
    }

    function test_renounceAdmin_disablesAllAdminPaths() public {
        vm.prank(admin);
        token.renounceAdmin();
        assertEq(token.admin(), address(0));
        // Original admin sticks around (used by `verify`)
        assertEq(token.originalAdmin(), admin);

        vm.prank(admin);
        vm.expectRevert(ArtCoinsToken.NotAdmin.selector);
        token.updateImage("x");

        vm.prank(admin);
        vm.expectRevert(ArtCoinsToken.NotAdmin.selector);
        token.setMetadataRenderer(address(0));
    }

    function test_updateImage() public {
        vm.prank(admin);
        token.updateImage("new-image.png");
        assertEq(token.imageUrl(), "new-image.png");
    }

    function test_updateImageRevertsIfNotAdmin() public {
        vm.prank(user1);
        vm.expectRevert(ArtCoinsToken.NotAdmin.selector);
        token.updateImage("x");
    }

    function test_updateMetadata() public {
        vm.prank(admin);
        token.updateMetadata("new metadata");
        assertEq(token.metadata(), "new metadata");
    }

    function test_updateMetadataRevertsIfNotAdmin() public {
        vm.prank(user1);
        vm.expectRevert(ArtCoinsToken.NotAdmin.selector);
        token.updateMetadata("x");
    }

    // ─── Verify ─────────────────────────────────────────────────────────

    function test_verify() public {
        vm.prank(admin);
        token.verify();
        assertTrue(token.isVerified());
    }

    function test_verifyRevertsIfNotOriginalAdmin() public {
        vm.prank(admin);
        token.updateAdmin(user1);

        vm.prank(user1);
        vm.expectRevert(ArtCoinsToken.NotOriginalAdmin.selector);
        token.verify();
    }

    function test_doubleVerifyReverts() public {
        vm.prank(admin);
        token.verify();

        vm.prank(admin);
        vm.expectRevert(ArtCoinsToken.AlreadyVerified.selector);
        token.verify();
    }

    // ─── ERC20 functionality ────────────────────────────────────────────

    function test_transfer() public {
        token.transfer(user1, 1000e18);
        assertEq(token.balanceOf(user1), 1000e18);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1000e18);
    }

    function test_approve_transferFrom() public {
        token.approve(user1, 500e18);
        vm.prank(user1);
        token.transferFrom(address(this), user2, 500e18);
        assertEq(token.balanceOf(user2), 500e18);
    }

    function test_burn() public {
        uint256 burnAmount = 1000e18;
        token.burn(burnAmount);
        assertEq(token.totalSupply(), SUPPLY - burnAmount);
    }

    function test_burnFrom() public {
        token.transfer(user1, 1000e18);
        vm.prank(user1);
        token.approve(user2, 500e18);

        vm.prank(user2);
        token.burnFrom(user1, 500e18);

        assertEq(token.balanceOf(user1), 500e18);
        assertEq(token.totalSupply(), SUPPLY - 500e18);
    }

    // ─── Permit2 short-circuit (Solady) ─────────────────────────────────

    /// @notice Fresh holder who has never called `approve` reads max for PERMIT2.
    function test_allowanceForPermit2IsAlwaysMax_freshHolder() public {
        token.transfer(user1, 1000e18);
        assertEq(token.allowance(user1, PERMIT2), type(uint256).max);
        // And for any random address that holds zero too.
        assertEq(token.allowance(address(0xC0FFEE), PERMIT2), type(uint256).max);
    }

    /// @notice State changes don't perturb the view.
    function test_allowanceForPermit2IsMax_evenAfterTransfers() public {
        token.transfer(user1, 1000e18);
        vm.prank(user1);
        token.transfer(user2, 400e18);
        token.transfer(user1, 250e18);

        assertEq(token.allowance(user1, PERMIT2), type(uint256).max);
        assertEq(token.allowance(user2, PERMIT2), type(uint256).max);
    }

    /// @notice `approve(PERMIT2, x)` reverts for any `x != type(uint256).max`.
    function testFuzz_approvePermit2WithNonMaxReverts(uint256 amount) public {
        vm.assume(amount != type(uint256).max);
        vm.expectRevert(SoladyERC20.Permit2AllowanceIsFixedAtInfinity.selector);
        token.approve(PERMIT2, amount);
    }

    /// @notice `approve(PERMIT2, type(uint256).max)` succeeds — the only allowed
    ///         input. Allowance view continues to read max.
    function test_approvePermit2WithMaxSucceeds() public {
        bool ok = token.approve(PERMIT2, type(uint256).max);
        assertTrue(ok);
        assertEq(token.allowance(address(this), PERMIT2), type(uint256).max);
    }

    /// @notice The whole point: PERMIT2 can move tokens via `transferFrom` from
    ///         a holder who has never called `approve`. This is what allows the
    ///         frontend to skip the legacy `token.approve(permit2, MAX)` step.
    function test_permit2CanTransferFromWithoutAnyApproval() public {
        token.transfer(user1, 1000e18);
        assertEq(token.balanceOf(user1), 1000e18);

        vm.prank(PERMIT2);
        token.transferFrom(user1, user2, 600e18);

        assertEq(token.balanceOf(user1), 400e18);
        assertEq(token.balanceOf(user2), 600e18);
        // The Permit2 view still reads max — no debit happened.
        assertEq(token.allowance(user1, PERMIT2), type(uint256).max);
    }

    /// @notice Sanity: non-Permit2 spenders behave like a normal ERC20 — the
    ///         short-circuit doesn't widen behavior to other addresses.
    function test_nonPermit2SpenderBehavesNormally() public {
        token.transfer(user1, 1000e18);

        vm.prank(user1);
        token.approve(user2, 500e18);
        assertEq(token.allowance(user1, user2), 500e18);

        vm.prank(user2);
        token.transferFrom(user1, user2, 300e18);
        assertEq(token.allowance(user1, user2), 200e18);

        // Spending more than remaining allowance reverts (Solady InsufficientAllowance).
        vm.prank(user2);
        vm.expectRevert(SoladyERC20.InsufficientAllowance.selector);
        token.transferFrom(user1, user2, 250e18);
    }

    /// @notice EIP-2612 `permit()` cannot persist a non-max PERMIT2 allowance —
    ///         the same chokepoint catches it. Solady reverts this in `permit()`
    ///         before checking the signature, so we don't need a real signature.
    function test_permitCannotPersistNonMaxPermit2Allowance() public {
        // Any value < max with PERMIT2 as spender must revert with the fixed-at-
        // infinity error before sig recovery runs.
        bytes32 r = bytes32(0);
        bytes32 s = bytes32(0);
        uint8 v = 27;
        vm.expectRevert(SoladyERC20.Permit2AllowanceIsFixedAtInfinity.selector);
        token.permit(address(this), PERMIT2, 1, block.timestamp + 1 days, v, r, s);
    }

    // ─── Metadata / contractURI / tokenURI ──────────────────────────────

    function test_contractURI_default() public view {
        string memory uri = token.contractURI();
        assertTrue(bytes(uri).length > 35);
        assertTrue(_startsWith(uri, "data:application/json;base64,"));
    }

    function test_tokenURI_matchesContractURI() public view {
        assertEq(token.tokenURI(), token.contractURI());
    }

    function test_contractURI_withRenderer() public {
        MockRenderer renderer = new MockRenderer();
        vm.prank(admin);
        token.setMetadataRenderer(address(renderer));

        assertEq(token.contractURI(), renderer.MOCK_URI());
        assertEq(token.tokenURI(), renderer.MOCK_URI());
    }

    function test_setMetadataRenderer() public {
        MockRenderer renderer = new MockRenderer();
        vm.prank(admin);
        token.setMetadataRenderer(address(renderer));
        assertEq(token.metadataRenderer(), address(renderer));
    }

    function test_setMetadataRendererRevertsIfNotAdmin() public {
        vm.prank(user1);
        vm.expectRevert(ArtCoinsToken.NotAdmin.selector);
        token.setMetadataRenderer(address(0x1));
    }

    function test_setMetadataRendererRevertsOnEoa() public {
        vm.prank(admin);
        vm.expectRevert(ArtCoinsToken.InvalidRenderer.selector);
        token.setMetadataRenderer(user1);
    }

    function test_escapeJson_handlesControlCharacters() public {
        string memory weird = string(abi.encodePacked("line1\nline2\twith\x01control"));
        vm.prank(admin);
        token.updateMetadata(weird);

        string memory uri = token.contractURI();
        bytes memory prefix = bytes("data:application/json;base64,");
        bytes memory uriB = bytes(uri);
        bytes memory b64 = new bytes(uriB.length - prefix.length);
        for (uint256 i = 0; i < b64.length; i++) {
            b64[i] = uriB[i + prefix.length];
        }
        string memory json = string(Base64.decode(string(b64)));
        assertTrue(_contains(json, "line1\\nline2\\twith\\u0001control"));
    }

    function test_setMetadataRenderer_backToZero() public {
        MockRenderer renderer = new MockRenderer();
        vm.startPrank(admin);
        token.setMetadataRenderer(address(renderer));
        assertEq(token.contractURI(), renderer.MOCK_URI());

        token.setMetadataRenderer(address(0));
        assertTrue(_startsWith(token.contractURI(), "data:application/json;base64,"));
        vm.stopPrank();
    }

    function test_defaultRenderer() public {
        DefaultMetadataRenderer renderer = new DefaultMetadataRenderer();
        vm.prank(admin);
        token.setMetadataRenderer(address(renderer));

        string memory uri = token.contractURI();
        assertTrue(_startsWith(uri, "data:application/json;base64,"));
    }

    // ─── supportsInterface ──────────────────────────────────────────────

    function test_supportsInterface() public view {
        assertTrue(token.supportsInterface(type(IERC20).interfaceId));
        assertTrue(token.supportsInterface(type(IERC165).interfaceId));
        assertFalse(token.supportsInterface(bytes4(0x12345678)));
    }

    // ─── JSON escaping ──────────────────────────────────────────────────

    function test_contractURI_specialChars() public {
        vm.startPrank(admin);
        token.updateMetadata('has "quotes" and \\backslash');
        vm.stopPrank();

        string memory uri = token.contractURI();
        assertTrue(bytes(uri).length > 0);
    }

    // ─── Helpers ────────────────────────────────────────────────────────

    function _startsWith(string memory str, string memory prefix) internal pure returns (bool) {
        bytes memory strBytes = bytes(str);
        bytes memory prefixBytes = bytes(prefix);
        if (strBytes.length < prefixBytes.length) return false;
        for (uint256 i = 0; i < prefixBytes.length; i++) {
            if (strBytes[i] != prefixBytes[i]) return false;
        }
        return true;
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0) return true;
        if (n.length > h.length) return false;
        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool ok = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }
}
