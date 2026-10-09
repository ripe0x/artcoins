// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {Constants} from "../../src/Constants.sol";
import {IMetadataRenderer} from "../../src/interfaces/IMetadataRenderer.sol";
import {DefaultMetadataRendererV2} from "../../src/v2/renderer/DefaultMetadataRendererV2.sol";
import {DynamicBlockRendererV2} from "../../src/v2/renderer/DynamicBlockRendererV2.sol";
import {ExampleOnChainRendererV2} from "../../src/v2/renderer/ExampleOnChainRendererV2.sol";
import {IBuySellCounter, SpriteRendererV2} from "../../src/v2/renderer/SpriteRendererV2.sol";
import {SvgText} from "../../src/v2/renderer/SvgText.sol";

import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";

/// @dev Exposes every field the renderers read. Any string, any length.
contract RenderStubToken {
    string public name;
    string public symbol;
    string public description;
    string public imageUrl;
    uint256 public totalSupply = 1_000_000_000e18;

    function set(string memory n, string memory s, string memory m, string memory i) external {
        name = n;
        symbol = s;
        description = m;
        imageUrl = i;
    }
}

contract StubCounter is IBuySellCounter {
    uint128 public buys;
    uint128 public sells;

    function set(uint128 b, uint128 s) external {
        buys = b;
        sells = s;
    }

    function countsForToken(address) external view returns (uint128, uint128) {
        return (buys, sells);
    }
}

/// @notice Tests for package r1: SvgText, the v2 renderers, and the review
///         injection proofs (R1, R2, R3) flipped into regressions.
contract RendererV2Test is Test {
    string internal constant JSON_PREFIX = "data:application/json;base64,";
    string internal constant SVG_PREFIX = "data:image/svg+xml;base64,";

    RenderStubToken internal tok;
    RenderStubToken internal benign;
    StubCounter internal counter;
    DefaultMetadataRendererV2 internal def;
    DynamicBlockRendererV2 internal dyn;
    ExampleOnChainRendererV2 internal ex;
    SpriteRendererV2 internal sprite;

    function setUp() public {
        vm.roll(1000);
        vm.warp(1_800_000_000);
        tok = new RenderStubToken();
        benign = new RenderStubToken();
        benign.set("Benign", "BEN", "plain description", "ipfs://bafy");
        counter = new StubCounter();
        counter.set(10, 5);
        def = new DefaultMetadataRendererV2();
        dyn = new DynamicBlockRendererV2();
        ex = new ExampleOnChainRendererV2();
        sprite = new SpriteRendererV2(IBuySellCounter(address(counter)), "https://anim.example");
    }

    // ─── helpers ───────────────────────────────────────────────────────

    /// @dev raw bytes as a string (solidity rejects invalid utf8 in `string(hex"..")`).
    function _s(bytes memory b) internal pure returns (string memory) {
        return string(b);
    }

    function _all() internal view returns (IMetadataRenderer[4] memory rs) {
        rs = [
            IMetadataRenderer(address(def)),
            IMetadataRenderer(address(dyn)),
            IMetadataRenderer(address(ex)),
            IMetadataRenderer(address(sprite))
        ];
    }

    function _svgRenderers() internal view returns (IMetadataRenderer[3] memory rs) {
        rs = [
            IMetadataRenderer(address(dyn)),
            IMetadataRenderer(address(ex)),
            IMetadataRenderer(address(sprite))
        ];
    }

    /// @dev strict: the prefix must match and the base64 must round trip.
    function _decode(string memory uri, string memory prefix)
        internal
        pure
        returns (string memory)
    {
        assertTrue(LibString.startsWith(uri, prefix), "missing data uri prefix");
        string memory b64 = LibString.slice(uri, bytes(prefix).length);
        bytes memory raw = Base64.decode(b64);
        assertEq(Base64.encode(raw), b64, "base64 does not round trip");
        return string(raw);
    }

    function _json(IMetadataRenderer r, address token) internal view returns (string memory) {
        return _decode(r.contractURI(token), JSON_PREFIX);
    }

    function _svg(IMetadataRenderer r, address token) internal view returns (string memory) {
        string memory img = vm.parseJsonString(_json(r, token), ".image");
        return _decode(img, SVG_PREFIX);
    }

    function _count(string memory hay, bytes1 c) internal pure returns (uint256 n) {
        bytes memory b = bytes(hay);
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == c) n++;
        }
    }

    function _contains(string memory hay, string memory needle) internal pure returns (bool) {
        return LibString.contains(hay, needle);
    }

    function _rep(bytes1 c, uint256 n) internal pure returns (string memory) {
        bytes memory b = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            b[i] = c;
        }
        return string(b);
    }

    /// @dev independent strict utf8 validator (not the library's logic).
    function _validUtf8(bytes memory b) internal pure returns (bool) {
        uint256 i;
        uint256 n = b.length;
        while (i < n) {
            uint8 c = uint8(b[i]);
            if (c < 0x80) {
                i++;
                continue;
            }
            uint256 len;
            uint256 cp;
            if (c >= 0xC2 && c <= 0xDF) {
                len = 2;
                cp = c & 0x1f;
            } else if (c >= 0xE0 && c <= 0xEF) {
                len = 3;
                cp = c & 0x0f;
            } else if (c >= 0xF0 && c <= 0xF4) {
                len = 4;
                cp = c & 0x07;
            } else {
                return false;
            }
            if (i + len > n) return false;
            for (uint256 j = 1; j < len; j++) {
                uint8 d = uint8(b[i + j]);
                if (d & 0xC0 != 0x80) return false;
                cp = (cp << 6) | (d & 0x3f);
            }
            if (len == 3 && cp < 0x800) return false;
            if (len == 4 && (cp < 0x10000 || cp > 0x10FFFF)) return false;
            if (cp >= 0xD800 && cp <= 0xDFFF) return false;
            i += len;
        }
        return true;
    }

    /// @dev valid utf8 and only xml 1.0 characters.
    function _validXml(bytes memory b) internal pure returns (bool) {
        if (!_validUtf8(b)) return false;
        for (uint256 i = 0; i < b.length; i++) {
            uint8 c = uint8(b[i]);
            if (c < 0x20 && c != 0x09 && c != 0x0a && c != 0x0d) return false;
            if (c == 0xef && i + 2 < b.length && uint8(b[i + 1]) == 0xbf && uint8(b[i + 2]) >= 0xbe)
            {
                return false;
            }
        }
        return true;
    }

    /// @dev every `&` starts one of the five entities the escaper emits.
    function _entitiesOk(bytes memory b) internal pure returns (bool) {
        string[5] memory ents = ["&amp;", "&lt;", "&gt;", "&quot;", "&#39;"];
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] != "&") continue;
            bool ok;
            for (uint256 e = 0; e < ents.length && !ok; e++) {
                bytes memory eb = bytes(ents[e]);
                if (i + eb.length > b.length) continue;
                bool m = true;
                for (uint256 k = 0; k < eb.length; k++) {
                    if (b[i + k] != eb[k]) {
                        m = false;
                        break;
                    }
                }
                ok = m;
            }
            if (!ok) return false;
        }
        return true;
    }

    /// @dev simple balanced quote / brace / bracket scan with escape handling.
    function _jsonBalanced(bytes memory b) internal pure returns (bool) {
        bool inStr;
        bool esc;
        int256 brace;
        int256 brack;
        for (uint256 i = 0; i < b.length; i++) {
            bytes1 c = b[i];
            if (inStr) {
                if (esc) {
                    esc = false;
                } else if (c == "\\") {
                    esc = true;
                } else if (c == '"') {
                    inStr = false;
                } else if (uint8(c) < 0x20) {
                    return false;
                }
            } else if (c == '"') {
                inStr = true;
            } else if (c == "{") {
                brace++;
            } else if (c == "}") {
                if (--brace < 0) return false;
            } else if (c == "[") {
                brack++;
            } else if (c == "]") {
                if (--brack < 0) return false;
            }
        }
        return !inStr && !esc && brace == 0 && brack == 0;
    }

    /// @dev full structural check of every renderer's output for the current `tok`.
    function _checkAll() internal {
        IMetadataRenderer[4] memory rs = _all();
        for (uint256 i = 0; i < rs.length; i++) {
            string memory json = _json(rs[i], address(tok));
            assertTrue(_validUtf8(bytes(json)), "json not utf8");
            assertTrue(_jsonBalanced(bytes(json)), "json not balanced");
            // a real parser accepts it and the fields round trip through escapeJSON.
            assertEq(
                vm.parseJsonString(json, ".name"),
                SvgText.clean(tok.name(), SvgText.NAME_MAX),
                "name round trip"
            );
            assertEq(
                vm.parseJsonString(json, ".symbol"),
                SvgText.clean(tok.symbol(), SvgText.SYMBOL_MAX),
                "symbol round trip"
            );
            vm.parseJsonString(json, ".image");
        }
        // the sprite draws an <image> only when the cleaned url is non empty.
        bool hasImage = bytes(SvgText.cleanOrEmpty(tok.imageUrl(), SvgText.URL_MAX)).length != 0;
        benign.set("Benign", "BEN", "plain description", hasImage ? "ipfs://bafy" : "");
        IMetadataRenderer[3] memory sv = _svgRenderers();
        for (uint256 i = 0; i < sv.length; i++) {
            string memory svg = _svg(sv[i], address(tok));
            string memory ref = _svg(sv[i], address(benign));
            assertTrue(_validXml(bytes(svg)), "svg not valid xml chars");
            assertTrue(_entitiesOk(bytes(svg)), "raw ampersand in svg");
            // no markup from the token: same tag count as a benign token.
            assertEq(_count(svg, "<"), _count(ref, "<"), "foreign markup in svg");
            assertEq(_count(svg, ">"), _count(ref, ">"), "foreign markup in svg (>)");
        }
    }

    // ─── escaping ───────────────────────────────────────────────────────

    string internal constant EVIL = "</text><script>alert(1)</script>&";

    function test_renderV2_escapesAngleAndAmp() public {
        tok.set(EVIL, EVIL, EVIL, EVIL);
        IMetadataRenderer[3] memory sv = _svgRenderers();
        for (uint256 i = 0; i < sv.length; i++) {
            // data uri decodes, json parses, name survives json round trip.
            string memory json = _json(sv[i], address(tok));
            assertEq(vm.parseJsonString(json, ".name"), EVIL, "json name");
            string memory svg = _svg(sv[i], address(tok));
            string memory ref = _svg(sv[i], address(benign));
            assertTrue(_contains(svg, "&lt;"), "no escaped lt");
            assertFalse(_contains(svg, "<script"), "script tag");
            assertFalse(_contains(svg, "</text><script"), "text node closed");
            assertEq(_count(svg, "<"), _count(ref, "<"), "raw < from input");
            assertTrue(_entitiesOk(bytes(svg)), "raw &");
        }
        // text nodes (dynamic block, example)
        string memory dsvg = _svg(dyn, address(tok));
        assertTrue(_contains(dsvg, "&lt;/text&gt;&lt;script&gt;alert(1)&lt;/"), "dyn name escaped");
        string memory esvg = _svg(ex, address(tok));
        assertTrue(
            _contains(esvg, "&lt;/text&gt;&lt;script&gt;alert(1)&lt;/"), "example name escaped"
        );
        // attribute value (sprite href)
        string memory ssvg = _svg(sprite, address(tok));
        assertTrue(
            _contains(ssvg, 'href="&lt;/text&gt;&lt;script&gt;alert(1)&lt;/script&gt;&amp;"'),
            "sprite href escaped"
        );
        // default renderer is json only: still valid json.
        assertEq(vm.parseJsonString(_json(def, address(tok)), ".description"), EVIL);
    }

    function test_renderV2_escapesQuotesBothKinds() public {
        tok.set("x", "a\"b'c", "d", "u\"v'w");
        string memory esvg = _svg(ex, address(tok));
        assertTrue(_contains(esvg, ">a&quot;b&#39;c</text>"), "quotes in text node");
        string memory ssvg = _svg(sprite, address(tok));
        assertTrue(_contains(ssvg, 'href="u&quot;v&#39;w"'), "quotes in attribute");
    }

    // ─── review proofs flipped: R1 ──────────────────────────────────────

    string internal constant SVG_PAYLOAD = '</text><image href="//x.i"/>';

    function test_renderV2_R1_dynamicBlockNameCannotInjectMarkup() public {
        tok.set(SVG_PAYLOAD, "SYM", "d", "i");
        string memory svg = _svg(dyn, address(tok));
        assertFalse(_contains(svg, '<image href="//x.i"/>'), "markup injected");
        assertFalse(_contains(svg, "</text></text>"), "extra close");
        assertTrue(
            _contains(svg, "&lt;/text&gt;&lt;image href=&quot;//x.i&quot;/&gt;"), "not escaped"
        );
    }

    function test_renderV2_R1_exampleNameCannotInjectMarkup() public {
        tok.set(SVG_PAYLOAD, "SYM", "d", "i");
        string memory svg = _svg(ex, address(tok));
        assertFalse(_contains(svg, '<image href="//x.i"/>'), "markup injected");
        assertTrue(
            _contains(svg, "&lt;/text&gt;&lt;image href=&quot;//x.i&quot;/&gt;"), "not escaped"
        );
    }

    function test_renderV2_R1_ampersandSymbolKeepsXmlValid() public {
        tok.set("n", "A&B", "d", "i");
        string memory svg = _svg(ex, address(tok));
        assertTrue(_contains(svg, ">A&amp;B</text>"), "ampersand not escaped");
        assertFalse(_contains(svg, ">A&B</text>"), "raw ampersand");
        string memory dsvg = _svg(dyn, address(tok));
        assertTrue(_contains(dsvg, ">A&amp;B</text>"), "dynamic ampersand");
    }

    // ─── review proofs flipped: R2 (utf8 truncation) ────────────────────

    function test_renderV2_R2_dynamicTruncationDoesNotSplitEuro() public {
        // "a" + 11 x U+20AC = 34 bytes. cut at 30 lands inside the 10th euro.
        string memory n = "a";
        for (uint256 i = 0; i < 11; i++) {
            n = string.concat(n, unicode"€");
        }
        tok.set(n, "S", "d", "i");
        string memory svg = _svg(dyn, address(tok));
        assertFalse(_contains(svg, string(abi.encodePacked(hex"e282", "</text>"))), "split euro");
        string memory want = "a";
        for (uint256 i = 0; i < 9; i++) {
            want = string.concat(want, unicode"€");
        }
        assertTrue(_contains(svg, string.concat(">", want, "</text>")), "expected 9 euros");
        assertTrue(_validUtf8(bytes(svg)), "svg not utf8");
    }

    // ─── review proofs flipped: R3 (sprite href) ────────────────────────

    function test_renderV2_R3_spriteImageUrlCannotBreakOutOfHref() public {
        tok.set("n", "s", "d", 'x"/><script>alert(1)</script><image href="y');
        string memory svg = _svg(sprite, address(tok));
        assertFalse(_contains(svg, "<script"), "script injected");
        assertFalse(_contains(svg, '<image href="x"/>'), "attribute broken out");
        assertTrue(_contains(svg, 'href="x&quot;/&gt;&lt;script&gt;'), "not escaped");
        // same tag count as a benign token: nothing from the url became markup.
        assertEq(_count(svg, "<"), _count(_svg(sprite, address(benign)), "<"), "foreign markup");
        assertTrue(_entitiesOk(bytes(svg)));
    }

    function test_renderV2_R3_spriteAnimationUrlIsJsonEscaped() public {
        SpriteRendererV2 s = new SpriteRendererV2(
            IBuySellCounter(address(counter)), 'https://a.example/","name":"pwned\\'
        );
        tok.set("n", "s", "d", "i");
        string memory json = _json(s, address(tok));
        string memory anim = vm.parseJsonString(json, ".animation_url");
        assertEq(
            anim,
            string.concat(
                'https://a.example/","name":"pwned\\/',
                LibString.toString(block.chainid),
                "/",
                LibString.toHexString(address(tok))
            )
        );
        assertEq(vm.parseJsonString(json, ".name"), "n", "name overwritten by injected key");
    }

    function test_renderV2_spriteRejectsOversizeAnimationBase() public {
        string memory big = _rep("a", SvgText.URL_MAX + 1);
        vm.expectRevert(SpriteRendererV2.AnimationUrlTooLong.selector);
        new SpriteRendererV2(IBuySellCounter(address(counter)), big);
    }

    // ─── utf8 truncation ────────────────────────────────────────────────

    function test_renderV2_truncateNeverSplitsUtf8() public pure {
        // A(1) e-acute(2) euro(3) emoji(4) z(1): boundaries 0,1,3,6,10,11.
        bytes memory mixed = bytes(unicode"Aé€😀z");
        assertEq(mixed.length, 11);
        uint256[6] memory bounds = [uint256(0), 1, 3, 6, 10, 11];
        for (uint256 k = 0; k <= 14; k++) {
            bytes memory out = bytes(SvgText.clean(string(mixed), k));
            uint256 want;
            for (uint256 b = 0; b < bounds.length; b++) {
                if (bounds[b] <= k) want = bounds[b];
            }
            assertEq(out.length, want, "not the longest whole character prefix");
            for (uint256 i = 0; i < out.length; i++) {
                assertEq(out[i], mixed[i], "not a prefix");
            }
            assertTrue(_validUtf8Pure(out), "split sequence");
            // text() and attr() share the cut.
            assertEq(bytes(SvgText.text(string(mixed), k)).length, want);
            assertEq(bytes(SvgText.attr(string(mixed), k)).length, want);
        }
    }

    function _validUtf8Pure(bytes memory b) internal pure returns (bool) {
        return _validUtf8(b);
    }

    function test_renderV2_truncateNeverSplitsUtf8_inRenderers() public {
        // 4 byte emoji straddling the cut: example symbol cap is 6 bytes.
        tok.set("n", string.concat("AAAAA", unicode"😀"), "d", "i");
        string memory esvg = _svg(ex, address(tok));
        assertTrue(_contains(esvg, ">AAAAA</text>"), "emoji kept half");
        // dynamic name cap is 30 bytes: 28 ascii + emoji straddles 28..32.
        tok.set(string.concat(_rep("a", 28), unicode"😀"), "S", "d", "i");
        string memory dsvg = _svg(dyn, address(tok));
        assertTrue(_contains(dsvg, string.concat(">", _rep("a", 28), "</text>")), "emoji kept half");
        assertTrue(_validXml(bytes(dsvg)));
        // emoji that fits whole is kept: 26 ascii + emoji = 30 bytes.
        tok.set(string.concat(_rep("a", 26), unicode"😀"), "S", "d", "i");
        dsvg = _svg(dyn, address(tok));
        assertTrue(
            _contains(dsvg, string.concat(">", _rep("a", 26), unicode"😀", "</text>")),
            "whole emoji dropped"
        );
    }

    function test_renderV2_cleanReplacesInvalidAndControl() public pure {
        assertEq(SvgText.clean(_s(hex"c080"), 99), "??", "overlong");
        assertEq(SvgText.clean(_s(hex"eda080"), 99), "???", "surrogate");
        assertEq(SvgText.clean(_s(hex"f4908080"), 99), "????", "above 10ffff");
        assertEq(SvgText.clean(_s(hex"f5"), 99), "?", "bad lead");
        assertEq(SvgText.clean(_s(hex"80"), 99), "?", "stray continuation");
        assertEq(SvgText.clean(_s(hex"41e282"), 99), "A??", "truncated tail");
        assertEq(SvgText.clean(_s(hex"efbfbe"), 99), "?", "u+fffe");
        assertEq(SvgText.clean(_s(hex"efbfbf"), 99), "?", "u+ffff");
        assertEq(SvgText.clean(_s(hex"c285"), 99), " ", "c1 control");
        assertEq(SvgText.clean(_s(hex"c2a0"), 99), _s(hex"c2a0"), "nbsp kept");
        assertEq(SvgText.clean(_s(hex"610a0b0d097f00"), 99), "a      ", "c0 and del");
        assertEq(SvgText.clean(_s(hex"f09f9880"), 99), _s(hex"f09f9880"), "emoji kept");
        assertEq(SvgText.clean(_s(hex"f48fbfbf"), 99), _s(hex"f48fbfbf"), "u+10ffff kept");
        assertEq(SvgText.clean("", 99), "");
        assertEq(SvgText.clean("abc", 0), "");
        assertEq(SvgText.cleanOrEmpty("abcd", 3), "", "over cap dropped");
        assertEq(SvgText.cleanOrEmpty("abc", 3), "abc");
    }

    function testFuzz_renderV2_cleanAlwaysValidAndBounded(bytes memory b, uint16 max) public pure {
        bytes memory out = bytes(SvgText.clean(string(b), max));
        assertLe(out.length, b.length);
        assertLe(out.length, max);
        assertTrue(_validXml(out), "clean output not valid xml text");
        // free memory pointer stays word aligned and past the string.
        uint256 fmp;
        assembly {
            fmp := mload(0x40)
        }
        assertEq(fmp % 32, 0);
    }

    function testFuzz_renderV2_cleanKeepsValidPrintableUtf8(string memory s) public pure {
        bytes memory b = bytes(s);
        vm.assume(_validXml(b));
        // control chars become spaces, so only compare when none present.
        for (uint256 i = 0; i < b.length; i++) {
            vm.assume(uint8(b[i]) >= 0x20 && uint8(b[i]) != 0x7f);
            vm.assume(!(uint8(b[i]) == 0xc2 && i + 1 < b.length && uint8(b[i + 1]) < 0xa0));
        }
        assertEq(SvgText.clean(s, type(uint256).max), s);
    }

    // ─── structure for arbitrary bytes ──────────────────────────────────

    function testFuzz_renderV2_validForArbitraryNames(
        bytes memory n,
        bytes memory s,
        bytes memory d,
        bytes memory img
    ) public {
        tok.set(string(n), string(s), string(d), string(img));
        _checkAll();
    }

    /// @dev builds the four fields from a table of hostile pieces.
    function testFuzz_renderV2_validForHostilePieces(bytes memory seed) public {
        string[16] memory pieces = [
            "<",
            ">",
            "&",
            '"',
            "'",
            "\\",
            "</text>",
            "]]>",
            "\n",
            unicode"😀",
            unicode"€",
            _s(hex"ff"),
            _s(hex"e282"),
            "&amp;",
            "{\"a\":[",
            "a"
        ];
        string memory a;
        string memory b;
        string memory c;
        string memory dd;
        for (uint256 i = 0; i < seed.length && i < 120; i++) {
            string memory p = pieces[uint8(seed[i]) & 15];
            uint256 which = (uint8(seed[i]) >> 4) & 3;
            if (which == 0) a = string.concat(a, p);
            else if (which == 1) b = string.concat(b, p);
            else if (which == 2) c = string.concat(c, p);
            else dd = string.concat(dd, p);
        }
        tok.set(a, b, c, dd);
        _checkAll();
    }

    function test_renderV2_controlAndInvalidBytesYieldValidOutput() public {
        tok.set(_s(hex"610a0d0900ff41c0"), _s(hex"0180"), _s(hex"e282"), _s(hex"eda080"));
        _checkAll();
        tok.set(string(abi.encodePacked("a", hex"0a", "b")), "s", "d", "i");
        string memory svg = _svg(ex, address(tok));
        assertTrue(_contains(svg, "a b"), "newline not replaced");
    }

    // ─── gas ────────────────────────────────────────────────────────────

    function _gas(IMetadataRenderer r) internal view returns (uint256 used, uint256 len) {
        uint256 g = gasleft();
        string memory out = r.contractURI(address(tok));
        used = g - gasleft();
        len = bytes(out).length;
    }

    function _measureAll(string memory tag, bool assertCold) internal returns (uint256 worst) {
        IMetadataRenderer[4] memory rs = _all();
        for (uint256 i = 0; i < rs.length; i++) {
            (uint256 g, uint256 l) = _gas(rs[i]);
            console2.log(tag, "renderer", i);
            console2.log("  warm gas", g);
            console2.log("  bytes", l);
            if (assertCold) assertLt(g, Constants.RENDER_GAS_BUDGET, "warm over budget");
            if (g > worst) worst = g;
            // cold: the token's own storage priced at cold sload (the token pays
            // this on every read, whatever the renderer does with the result).
            vm.cool(address(tok));
            (g, l) = _gas(rs[i]);
            console2.log("  cold gas", g);
            if (assertCold) assertLt(g, Constants.RENDER_GAS_BUDGET, "cold over budget");
        }
    }

    /// @dev worst case at the sizes the renderers accept: every field at its
    ///      `SvgText` cap made of the worst expanding json char, both glyph layers
    ///      at `Constants.MAX_GLYPHS`. Warm and cold must fit `RENDER_GAS_BUDGET`.
    function test_renderV2_maxGlyphsUnderBudget() public {
        counter.set(type(uint128).max, type(uint128).max);
        tok.set(
            _rep('"', SvgText.NAME_MAX),
            _rep('"', SvgText.SYMBOL_MAX),
            _rep('"', SvgText.DESC_MAX),
            _rep('"', SvgText.URL_MAX)
        );
        uint256 worst = _measureAll("caps", true);
        console2.log("worst gas at caps", worst);
        // the sprite caps both glyph layers at Constants.MAX_GLYPHS.
        string memory svg = _svg(sprite, address(tok));
        assertEq(_count(svg, "+"), Constants.MAX_GLYPHS, "plus glyph count");
        assertEq(Constants.MAX_GLYPHS, sprite.MAX_GLYPHS());
    }

    /// @dev D30: the token rejects strings above its caps (name 64, symbol 16, image
    ///      url 2048, metadata 4096), so 24KB per field never reaches a renderer. The
    ///      renderers still truncate defensively: output must stay valid, gas is
    ///      logged only (the token's own sloads for 24KB are not the renderer's).
    function test_renderV2_oversizeTokenStringsStillValid() public {
        counter.set(type(uint128).max, type(uint128).max);
        string memory big = _rep('"', 24_000);
        tok.set(big, big, big, big);
        _checkAll();
        _measureAll("24kb", false);
    }

    /// @dev the assembly glyph writer matches an independent solidity reference
    ///      byte for byte (positions use v1's hash, digits have no leading zeros).
    function test_renderV2_spriteGlyphsMatchReference() public {
        tok.set("n", "s", "d", "");
        counter.set(300, 4);
        string memory want =
            '<g fill="#22c55e" font-family="monospace" font-size="40" font-weight="700" text-anchor="middle">';
        for (uint256 i = 0; i < Constants.MAX_GLYPHS; i++) {
            bytes32 h = keccak256(abi.encode(address(tok), uint256(0), i));
            want = string.concat(
                want,
                '<text x="',
                LibString.toString(uint256(h) % 1000),
                '" y="',
                LibString.toString((uint256(h) >> 128) % 1000),
                '">+</text>'
            );
        }
        want = string.concat(
            want,
            '</g><g fill="#ef4444" font-family="monospace" font-size="40" font-weight="700" text-anchor="middle">'
        );
        for (uint256 i = 0; i < 4; i++) {
            bytes32 h = keccak256(abi.encode(address(tok), uint256(1), i));
            want = string.concat(
                want,
                '<text x="',
                LibString.toString(uint256(h) % 1000),
                '" y="',
                LibString.toString((uint256(h) >> 128) % 1000),
                unicode'">−</text>'
            );
        }
        want = string.concat(want, "</g></svg>");
        string memory svg = _svg(sprite, address(tok));
        assertTrue(LibString.endsWith(svg, want), "glyph layers differ from reference");
    }

    function test_renderV2_spriteGlyphCountsFollowCounterAndCap() public {
        tok.set("n", "s", "d", "i");
        counter.set(3, 0);
        string memory svg = _svg(sprite, address(tok));
        assertEq(_count(svg, "+"), 3);
        assertFalse(_contains(svg, unicode"−"), "no sells, no minus layer");
        counter.set(1000, 7);
        svg = _svg(sprite, address(tok));
        assertEq(_count(svg, "+"), Constants.MAX_GLYPHS);
        assertEq(
            bytes(vm.parseJsonString(_json(sprite, address(tok)), ".description")).length > 0, true
        );
        assertEq(
            vm.parseJsonString(_json(sprite, address(tok)), ".description"), "Buys: 1000 | Sells: 7"
        );
    }

    function test_renderV2_spriteDropsOversizeImageUrl() public {
        tok.set("n", "s", "d", _rep("a", SvgText.URL_MAX + 1));
        string memory svg = _svg(sprite, address(tok));
        assertFalse(_contains(svg, "<image"), "oversize url kept");
        tok.set("n", "s", "d", "ipfs://ok");
        svg = _svg(sprite, address(tok));
        assertTrue(_contains(svg, '<image href="ipfs://ok" width="1000" height="1000"/>'));
    }

    function test_renderV2_measureRealistic() public {
        tok.set("Some Art Coin", "ART", "a short description", "ipfs://bafy");
        counter.set(150, 120);
        IMetadataRenderer[4] memory rs = _all();
        for (uint256 i = 0; i < rs.length; i++) {
            (uint256 g, uint256 l) = _gas(rs[i]);
            console2.log("realistic renderer / gas", i, g);
            console2.log("  bytes", l);
        }
    }
}
