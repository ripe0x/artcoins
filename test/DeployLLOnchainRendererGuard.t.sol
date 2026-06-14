// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DeployLLOnchainRenderer} from "../script/DeployLLOnchainRenderer.s.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Lock the deploy script's base64 guard against regression.
///         The guard exists because ScriptyBuilder tagType:2 splices the
///         on-chain content verbatim into `data:text/javascript;base64,...`.
///         Uploading raw JS produces a broken data URI on chain that the
///         browser silently fails to execute (no shapes, no animation).
///         These tests assert the guard rejects raw JS and accepts valid
///         base64 — encoding mistakes must fail the deploy script, not
///         the production token page.
contract DeployLLOnchainRendererGuardTest is Test {
    DeployLLOnchainRenderer internal harness;

    function setUp() public {
        harness = new DeployLLOnchainRenderer();
    }

    function test_acceptsValidBase64() public view {
        // Real prefix from sketch.js.b64 — pure base64 charset.
        harness._assertBase64Ascii(
            bytes("Ly8gTGlxdWlkaXR5IExheWVyIG9uLWNoYWluIGFuaW1hdGlvbiBza2V0Y2gu"), "test"
        );
    }

    function test_acceptsBase64WithNewlines() public view {
        // Some encoders wrap base64 at 76 cols. The renderer's data URI tolerates this.
        harness._assertBase64Ascii(bytes("abcDEF123+/=\nABCdef456"), "test");
    }

    function test_acceptsBase64WithCarriageReturn() public view {
        harness._assertBase64Ascii(bytes("abc\r\ndef"), "test");
    }

    function test_rejectsRawJs() public {
        // Raw sketch.js starts with `// Liquidity Layer ...` — the space at
        // offset 2 is outside the base64 charset.
        vm.expectRevert();
        harness._assertBase64Ascii(bytes("// Liquidity Layer on-chain animation sketch."), "test");
    }

    function test_rejectsBinaryGarbage() public {
        bytes memory bad = hex"00010203";
        vm.expectRevert();
        harness._assertBase64Ascii(bad, "test");
    }

    function test_rejectsUtf8Bom() public {
        // 0xEF 0xBB 0xBF prefix would slip past a "looks like text" check.
        bytes memory bad = bytes.concat(hex"EFBBBF", "abcdEFGH");
        vm.expectRevert();
        harness._assertBase64Ascii(bad, "test");
    }

    function test_rejectsEmpty() public {
        vm.expectRevert();
        harness._assertBase64Ascii(new bytes(0), "test");
    }

    function test_revertMessageNamesTheSource() public {
        try harness._assertBase64Ascii(bytes("not base64!"), "LL_SKETCH_PATH") {
            revert("expected revert");
        } catch Error(string memory reason) {
            // Message must mention the source string and the .b64 hint so the
            // operator immediately knows what to fix.
            assertTrue(_contains(reason, "LL_SKETCH_PATH"), "missing source name in revert");
            assertTrue(_contains(reason, ".js.b64"), "missing .b64 hint in revert");
        }
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return false;
        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool match_ = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    match_ = false;
                    break;
                }
            }
            if (match_) return true;
        }
        return false;
    }
}
