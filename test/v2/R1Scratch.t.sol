// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test, console2} from "forge-std/Test.sol";
import {SvgText} from "../../src/v2/renderer/SvgText.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Base64 as SB64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";
contract R1Scratch is Test {
    function test_prof() public {
        bytes memory b = new bytes(16384);
        for (uint256 i; i < b.length; i++) b[i] = '"';
        string memory s = string(b);
        uint256 g = gasleft();
        string memory c = SvgText.clean(s, 16384);
        console2.log("clean", g - gasleft());
        g = gasleft();
        string memory e = LibString.escapeJSON(c);
        console2.log("escapeJSON", g - gasleft(), bytes(e).length);
        g = gasleft();
        string memory j = string.concat('{"image":"', e, '"}');
        console2.log("concat", g - gasleft());
        g = gasleft();
        Base64.encode(bytes(j));
        console2.log("oz b64", g - gasleft());
        g = gasleft();
        SB64.encode(bytes(j));
        console2.log("solady b64", g - gasleft());
        g = gasleft();
        LibString.escapeHTML(c);
        console2.log("escapeHTML", g - gasleft());
    }
}
