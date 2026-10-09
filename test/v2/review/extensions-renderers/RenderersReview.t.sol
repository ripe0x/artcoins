// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Second-pass review proofs for src/renderer/** and the LL renderers in
// src/extensions/. No pool needed. See docs/v2/review/contracts-extensions-renderers.md.

import {Test, console2} from "forge-std/Test.sol";

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Base64 as SBase64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";

import {
    LiquidityLayerCounterPoolExtension
} from "../../../../src/extensions/LiquidityLayerCounterPoolExtension.sol";
import {
    LiquidityLayerOnchainRenderer
} from "../../../../src/extensions/LiquidityLayerOnchainRenderer.sol";
import {
    LiquidityLayerSpriteRenderer
} from "../../../../src/extensions/LiquidityLayerSpriteRenderer.sol";
import {IMetadataRenderer} from "../../../../src/interfaces/IMetadataRenderer.sol";
import {
    HTMLRequest,
    HTMLTag,
    IScriptyBuilderV2,
    IScriptyStorageV2
} from "../../../../src/interfaces/IScripty.sol";
import {DefaultMetadataRenderer} from "../../../../src/renderer/DefaultMetadataRenderer.sol";
import {DynamicBlockRenderer} from "../../../../src/renderer/DynamicBlockRenderer.sol";
import {ExampleOnChainRenderer} from "../../../../src/renderer/ExampleOnChainRenderer.sol";
import {MockScriptyStorage} from "../../../mocks/MockScriptyStorage.sol";

/// @dev Exposes every field the renderers read. Any string, any length.
contract RStubToken {
    string public name;
    string public symbol;
    // v1 renderers read `metadata()`, v2 renderers read `description()`; this
    // stub feeds the same value to both so one suite exercises every renderer.
    string public metadata;
    string public description;
    string public imageUrl;
    uint256 public totalSupply = 1_000_000_000e18;

    function set(string memory n, string memory s, string memory m, string memory i) external {
        name = n;
        symbol = s;
        metadata = m;
        description = m;
        imageUrl = i;
    }
}

/// @dev Approximates ScriptyBuilderV2.getHTMLString: tagType 1 inline
///      <script>, tagType 2 base64 data-uri <script src>, content pulled from
///      storage when contractAddress != 0. The real builder pre-sizes its
///      buffer, so this mock somewhat over-counts memory gas.
contract ScriptyLikeBuilder is IScriptyBuilderV2 {
    function getHTMLString(HTMLRequest calldata r) external view returns (string memory) {
        bytes memory body;
        for (uint256 i = 0; i < r.bodyTags.length; i++) {
            HTMLTag calldata t = r.bodyTags[i];
            bytes memory content = t.contractAddress != address(0)
                ? IScriptyStorageV2(t.contractAddress).getContent(t.name, t.contractData)
                : t.tagContent;
            if (t.tagType == 1) {
                body = bytes.concat(body, "<script>", content, "</script>");
            } else if (t.tagType == 2) {
                body = bytes.concat(
                    body,
                    '<script src="data:text/javascript;base64,',
                    bytes(Base64.encode(content)),
                    '"></script>'
                );
            } else {
                body = bytes.concat(body, t.tagOpen, content, t.tagClose);
            }
        }
        return string(bytes.concat("<html><head></head><body>", body, "</body></html>"));
    }
}

contract RenderersReviewTest is Test {
    using PoolIdLibrary for PoolKey;

    string constant JSON_PREFIX = "data:application/json;base64,";
    string constant SVG_PREFIX = "data:image/svg+xml;base64,";
    string constant HTML_PREFIX = "data:text/html;base64,";

    // 28 bytes: survives both _truncate(name, 28) and _truncate(name, 30).
    string constant SVG_PAYLOAD = '</text><image href="//x.i"/>';

    address hook = address(0xB00C);
    RStubToken tok;
    LiquidityLayerCounterPoolExtension counter;
    MockScriptyStorage store;
    ScriptyLikeBuilder builder;
    LiquidityLayerOnchainRenderer ll;
    LiquidityLayerSpriteRenderer sprite;
    PoolId pid;

    function setUp() public {
        vm.roll(1000);
        tok = new RStubToken();
        tok.set("Liquidity Layer", "LAYER", "desc", "ipfs://img");

        counter = new LiquidityLayerCounterPoolExtension(hook);
        PoolKey memory pk = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(tok)),
            fee: 0x800000,
            tickSpacing: 200,
            hooks: IHooks(hook)
        });
        pid = pk.toId();
        vm.prank(hook);
        counter.initializePreLockerSetup(pk, false, "");

        store = new MockScriptyStorage();
        // Real shipped assets (script-js/data/ll): mona.webp 20.5KB,
        // sketch.js 17KB, history.v1.bin 2.7KB (21.8K Base trades).
        store.set("mona", vm.readFileBinary("script-js/data/ll/mona.webp"));
        store.set("sketch", vm.readFileBinary("script-js/data/ll/sketch.js"));
        store.set("history", vm.readFileBinary("script-js/data/ll/history.v1.bin"));
        builder = new ScriptyLikeBuilder();
        ll = new LiquidityLayerOnchainRenderer(
            address(this),
            counter,
            builder,
            IScriptyStorageV2(address(store)),
            "sketch",
            "mona",
            "image/webp",
            "Liquidity Layer"
        );
        ll.setHistoryAsset("history");
        ll.setSupplyConfig(1_000_000_000e18, 18);

        sprite = new LiquidityLayerSpriteRenderer(counter, "https://ll.example/anim");
    }

    // ─── helpers ───────────────────────────────────────────────────────

    function _stripPrefix(string memory s, string memory p) internal pure returns (string memory) {
        assertTrue(LibString.startsWith(s, p), "missing data-uri prefix");
        return LibString.slice(s, bytes(p).length);
    }

    function _json(IMetadataRenderer r) internal view returns (string memory) {
        return string(SBase64.decode(_stripPrefix(r.contractURI(address(tok)), JSON_PREFIX)));
    }

    function _svg(IMetadataRenderer r) internal view returns (string memory) {
        string memory img = vm.parseJsonString(_json(r), ".image");
        return string(SBase64.decode(_stripPrefix(img, SVG_PREFIX)));
    }

    function _setTrades(uint256 buys, uint256 sells) internal {
        bytes32 slot = keccak256(abi.encode(PoolId.unwrap(pid), uint256(0)));
        vm.store(address(counter), slot, bytes32((sells << 128) | buys));
        assertEq(counter.totalTrades(pid), buys + sells);
    }

    function _gas(IMetadataRenderer r) internal view returns (uint256 used, uint256 len) {
        uint256 g = gasleft();
        string memory out = r.contractURI(address(tok));
        used = g - gasleft();
        len = bytes(out).length;
    }

    function _longString(uint256 n, bytes1 c) internal pure returns (string memory) {
        bytes memory b = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            b[i] = c;
        }
        return string(b);
    }

    // ─── R1: unescaped name/symbol in on-chain SVG <text> ──────────────

    function test_bug_R1_dynamicBlockRenderer_nameInjectsSvgMarkup() public {
        DynamicBlockRenderer r = new DynamicBlockRenderer();
        tok.set(SVG_PAYLOAD, "SYM", "d", "i");
        string memory svg = _svg(r);
        // the name closes the <text> element and opens an attacker <image>.
        assertTrue(LibString.contains(svg, '<image href="//x.i"/></text>'));
        assertTrue(LibString.contains(svg, string.concat(">", SVG_PAYLOAD, "</text>")));
    }

    function test_bug_R1_exampleOnChainRenderer_nameInjectsSvgMarkup() public {
        ExampleOnChainRenderer r = new ExampleOnChainRenderer();
        tok.set(SVG_PAYLOAD, "SYM", "d", "i");
        string memory svg = _svg(r);
        assertTrue(LibString.contains(svg, '<image href="//x.i"/></text>'));
    }

    function test_bug_R1_exampleOnChainRenderer_ampersandSymbolBreaksXml() public {
        ExampleOnChainRenderer r = new ExampleOnChainRenderer();
        tok.set("n", "A&B", "d", "i");
        string memory svg = _svg(r);
        // raw '&' not followed by an entity name + ';' is a fatal XML error:
        // the image fails to render in any strict SVG consumer.
        assertTrue(LibString.contains(svg, ">A&B</text>"));
        assertFalse(LibString.contains(svg, "&amp;"));
    }

    // ─── R2: byte-level truncation splits UTF-8 ────────────────────────

    function test_bug_R2_dynamicBlockRenderer_truncationSplitsUtf8() public {
        DynamicBlockRenderer r = new DynamicBlockRenderer();
        // "a" + 11 x U+20AC (3 bytes each) = 34 bytes; cut at 30 bytes leaves
        // a dangling 2-byte prefix (0xE2 0x82) of the 10th euro sign.
        string memory n = "a";
        for (uint256 i = 0; i < 11; i++) {
            n = string.concat(n, unicode"€");
        }
        tok.set(n, "S", "d", "i");
        string memory svg = _svg(r);
        assertTrue(LibString.contains(svg, string(abi.encodePacked(hex"e282", "</text>"))));
    }

    // ─── R3: LL sprite renderer puts token.imageUrl into an SVG attribute ──

    function test_bug_R3_spriteRenderer_imageUrlBreaksOutOfHrefAttribute() public {
        tok.set("n", "s", "d", 'x"/><script>alert(1)</script><image href="y');
        string memory svg = _svg(sprite);
        assertTrue(LibString.contains(svg, '<image href="x"/><script>alert(1)</script>'));
    }

    // ─── R4: LL on-chain renderer splices monaMimeType into inline JS ────

    function test_bug_R4_onchainRenderer_mimeTypeInjectsScript() public {
        ll.setMonaAsset("mona", 'image/webp";alert(document.domain);//');
        string memory anim = vm.parseJsonString(_json(ll), ".animation_url");
        string memory html = string(SBase64.decode(_stripPrefix(anim, HTML_PREFIX)));
        assertTrue(
            LibString.contains(
                html, 'window.LL_ASSETS={mona:"data:image/webp";alert(document.domain);//'
            )
        );
    }

    // ─── claim that holds: JSON string fields are escaped everywhere ────

    function test_holds_jsonEscapingRoundTripsHostileName() public {
        string memory nasty =
            string(abi.encodePacked('q"\\b', hex"0a01", "</script>]]><&", unicode"é€"));
        tok.set(nasty, nasty, nasty, nasty);
        IMetadataRenderer[5] memory rs = [
            IMetadataRenderer(address(new DefaultMetadataRenderer())),
            IMetadataRenderer(address(new DynamicBlockRenderer())),
            IMetadataRenderer(address(new ExampleOnChainRenderer())),
            IMetadataRenderer(address(sprite)),
            IMetadataRenderer(address(ll))
        ];
        for (uint256 i = 0; i < rs.length; i++) {
            string memory j = _json(rs[i]);
            assertEq(vm.parseJsonString(j, ".name"), nasty, "name not round-tripped");
            assertEq(vm.parseJsonString(j, ".symbol"), nasty, "symbol not round-tripped");
        }
    }

    // ─── G: gas ─────────────────────────────────────────────────────────

    function test_measure_G1_simpleRenderers_realisticAndLongStrings() public {
        IMetadataRenderer[3] memory rs = [
            IMetadataRenderer(address(new DefaultMetadataRenderer())),
            IMetadataRenderer(address(new DynamicBlockRenderer())),
            IMetadataRenderer(address(new ExampleOnChainRenderer()))
        ];
        for (uint256 i = 0; i < rs.length; i++) {
            tok.set("Some Art Coin", "ART", "a short description", "ipfs://bafy");
            (uint256 g0, uint256 l0) = _gas(rs[i]);
            // 24KB each in name, symbol, metadata, image (~100KB strings in
            // storage; costs the deployer ~16M gas of SSTOREs to set up).
            string memory big = _longString(24_000, "A");
            tok.set(big, big, big, big);
            (uint256 g1, uint256 l1) = _gas(rs[i]);
            console2.log("renderer", i);
            console2.log("  realistic gas / bytes", g0, l0);
            console2.log("  4x24KB strings gas / bytes", g1, l1);
            assertLt(g1, 30_000_000, "simple renderer near limits");
        }
    }

    function test_measure_G2_onchainRenderer_tradeCountScaling() public {
        uint256[6] memory ns = [uint256(0), 20_000, 250_000, 500_000, 1_000_000, 2_000_000];
        uint256 crossed;
        for (uint256 i = 0; i < ns.length; i++) {
            _setTrades(ns[i] / 2, ns[i] - ns[i] / 2);
            (uint256 g, uint256 l) = _gas(ll);
            console2.log("live trades", ns[i]);
            console2.log("  gas / bytes", g, l);
            if (crossed == 0 && g > 50_000_000) crossed = ns[i];
        }
        console2.log("first sample over 50M gas (geth rpc.gascap default):", crossed);
    }

    function test_measure_G3_spriteRenderer_maxGlyphs() public {
        _setTrades(1_000_000, 1_000_000); // both capped at MAX_GLYPHS = 200
        (uint256 g, uint256 l) = _gas(sprite);
        console2.log("sprite 200+200 glyphs gas / bytes", g, l);
        assertLt(g, 30_000_000);
    }
}
