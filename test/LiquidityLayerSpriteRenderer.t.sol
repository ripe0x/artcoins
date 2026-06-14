// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Test} from "forge-std/Test.sol";

import {
    LiquidityLayerCounterPoolExtension
} from "../src/extensions/LiquidityLayerCounterPoolExtension.sol";
import {LiquidityLayerSpriteRenderer} from "../src/extensions/LiquidityLayerSpriteRenderer.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// Minimal stub matching the renderer's `IRenderableToken` ABI.
contract RenderableTokenStub {
    string private _name;
    string private _symbol;
    string private _imageUrl;

    constructor(string memory n, string memory s, string memory img) {
        _name = n;
        _symbol = s;
        _imageUrl = img;
    }

    function name() external view returns (string memory) {
        return _name;
    }

    function symbol() external view returns (string memory) {
        return _symbol;
    }

    function imageUrl() external view returns (string memory) {
        return _imageUrl;
    }
}

contract LiquidityLayerSpriteRendererTest is Test {
    using PoolIdLibrary for PoolKey;

    LiquidityLayerCounterPoolExtension internal ext;
    LiquidityLayerSpriteRenderer internal renderer;
    RenderableTokenStub internal token;
    address internal hook = makeAddr("hook");

    string internal constant ANIMATION_BASE = "https://artcoins.com/embed";

    PoolKey internal pk;
    PoolId internal pid;

    function setUp() public {
        ext = new LiquidityLayerCounterPoolExtension(hook);
        renderer = new LiquidityLayerSpriteRenderer(ext, ANIMATION_BASE);
        token = new RenderableTokenStub("Liquidity Layer", "LL", "https://gateway.irys.xyz/abc123");

        // Build a pool where token is currency0 (nm = token0).
        address paired = makeAddr("paired");
        if (uint160(address(token)) > uint160(paired)) {
            (paired,) = (address(token), paired);
        }
        pk = PoolKey({
            currency0: Currency.wrap(
                uint160(address(token)) < uint160(paired) ? address(token) : paired
            ),
            currency1: Currency.wrap(
                uint160(address(token)) < uint160(paired) ? paired : address(token)
            ),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
        pid = pk.toId();
        bool nmIsToken0 = uint160(address(token)) < uint160(paired);

        vm.prank(hook);
        ext.initializePreLockerSetup(pk, nmIsToken0, "");

        // Helper closure: simulate trades. zeroForOne = isBuy XOR nmIsToken0.
        // We pre-compute one swap each to seed counts.
        _swap(true, nmIsToken0);
        _swap(false, nmIsToken0);
        _swap(true, nmIsToken0);
    }

    function _swap(bool isBuy, bool nmIsToken0) internal {
        bool zeroForOne = isBuy != nmIsToken0;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne, amountSpecified: -1 ether, sqrtPriceLimitX96: 0
        });
        vm.prank(hook);
        ext.afterSwap(pk, params, toBalanceDelta(0, 0), nmIsToken0, "");
    }

    // ─── Output shape ─────────────────────────────────────────────────

    function _decodeJsonUri(string memory uri) internal pure returns (string memory) {
        // uri == "data:application/json;base64,<payload>"
        bytes memory b = bytes(uri);
        bytes memory prefix = bytes("data:application/json;base64,");
        require(b.length > prefix.length, "uri too short");
        bytes memory payload = new bytes(b.length - prefix.length);
        for (uint256 i = 0; i < payload.length; i++) {
            payload[i] = b[prefix.length + i];
        }
        return string(Base64.decode(string(payload)));
    }

    function test_contractURI_isJsonDataUri() public view {
        string memory uri = renderer.contractURI(address(token));
        bytes memory b = bytes(uri);
        // Starts with the data:application/json prefix
        bytes memory prefix = bytes("data:application/json;base64,");
        for (uint256 i = 0; i < prefix.length; i++) {
            assertEq(b[i], prefix[i]);
        }
    }

    function test_contractURI_carriesNameSymbolDescription() public view {
        string memory json = _decodeJsonUri(renderer.contractURI(address(token)));
        assertTrue(_contains(json, '"name":"Liquidity Layer"'));
        assertTrue(_contains(json, '"symbol":"LL"'));
        // 2 buys + 1 sell from setUp's seed swaps.
        assertTrue(_contains(json, '"description":"Buys: 2 | Sells: 1"'));
    }

    function test_contractURI_carriesImageDataUri() public view {
        string memory json = _decodeJsonUri(renderer.contractURI(address(token)));
        assertTrue(_contains(json, '"image":"data:image/svg+xml;base64,'));
    }

    function test_contractURI_carriesAnimationUrl() public {
        // chainId in tests defaults to 31337; assert the URL composes correctly.
        vm.chainId(11_155_111);
        string memory json = _decodeJsonUri(renderer.contractURI(address(token)));
        // animation_url = "<base>/<chainId>/<token>"
        string memory expected =
            string.concat(ANIMATION_BASE, "/11155111/", _toLowerHex(address(token)));
        assertTrue(_contains(json, expected), "expected animation_url substring");
    }

    function test_contractURI_includesBaseImageInSvg() public view {
        string memory json = _decodeJsonUri(renderer.contractURI(address(token)));
        // Decode the SVG payload too.
        string memory svg = _extractSvgFromJson(json);
        assertTrue(_contains(svg, '<image href="https://gateway.irys.xyz/abc123"'));
    }

    function test_contractURI_emitsBuyAndSellGlyphs() public view {
        string memory json = _decodeJsonUri(renderer.contractURI(address(token)));
        string memory svg = _extractSvgFromJson(json);
        // 2 buys → 2 plus glyphs; 1 sell → 1 minus glyph
        // Exact string match is fragile because of position randomness, so
        // count occurrences of the literal glyph characters.
        assertEq(_countOccurrences(svg, ">+<"), 2);
        // Minus is unicode "−" (U+2212), not ASCII '-' — encoded as 3 bytes
        // in UTF-8: 0xE2 0x88 0x92. Search for that byte sequence.
        assertEq(_countByteSequence(bytes(svg), hex"3EE288923C"), 1); // ">−<"
    }

    function test_contractURI_emptyCountsRendersBaseImageOnly() public {
        // Use a fresh token with no swaps.
        RenderableTokenStub freshToken = new RenderableTokenStub("X", "X", "ipfs://x");
        // Bind it to a fresh pool so countsForToken returns 0/0.
        PoolKey memory pkFresh = PoolKey({
            currency0: Currency.wrap(address(freshToken)),
            currency1: Currency.wrap(makeAddr("p2")),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
        // currency0 must be < currency1; if not, swap.
        if (
            uint160(Currency.unwrap(pkFresh.currency0))
                > uint160(Currency.unwrap(pkFresh.currency1))
        ) {
            (pkFresh.currency0, pkFresh.currency1) = (pkFresh.currency1, pkFresh.currency0);
        }
        bool nmIsToken0 = uint160(address(freshToken)) < uint160(Currency.unwrap(pkFresh.currency1));
        if (Currency.unwrap(pkFresh.currency0) != address(freshToken)) {
            // Make sure freshToken IS currency0 so nmIsToken0 logic below works.
            // If we landed here freshToken is currency1, set nmIsToken0=false.
        }
        vm.prank(hook);
        ext.initializePreLockerSetup(pkFresh, nmIsToken0, "");

        string memory json = _decodeJsonUri(renderer.contractURI(address(freshToken)));
        assertTrue(_contains(json, '"description":"Buys: 0 | Sells: 0"'));
        string memory svg = _extractSvgFromJson(json);
        assertEq(_countOccurrences(svg, ">+<"), 0);
    }

    function test_contractURI_capsGlyphsAtMax() public {
        RenderableTokenStub bigToken = new RenderableTokenStub("Big", "B", "ipfs://big");
        PoolKey memory pkBig = PoolKey({
            currency0: Currency.wrap(address(bigToken)),
            currency1: Currency.wrap(makeAddr("p3")),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
        if (uint160(Currency.unwrap(pkBig.currency0)) > uint160(Currency.unwrap(pkBig.currency1))) {
            (pkBig.currency0, pkBig.currency1) = (pkBig.currency1, pkBig.currency0);
        }
        bool nmIsToken0 = Currency.unwrap(pkBig.currency0) == address(bigToken);
        vm.prank(hook);
        ext.initializePreLockerSetup(pkBig, nmIsToken0, "");

        // 250 buys (above MAX_GLYPHS = 200).
        for (uint256 i = 0; i < 250; i++) {
            bool zeroForOne = nmIsToken0 == false; // buy
            IPoolManager.SwapParams memory p = IPoolManager.SwapParams({
                zeroForOne: zeroForOne, amountSpecified: -1 ether, sqrtPriceLimitX96: 0
            });
            vm.prank(hook);
            ext.afterSwap(pkBig, p, toBalanceDelta(0, 0), nmIsToken0, "");
        }

        string memory json = _decodeJsonUri(renderer.contractURI(address(bigToken)));
        // Description still reflects the real total (250 buys, 0 sells).
        assertTrue(_contains(json, '"description":"Buys: 250 | Sells: 0"'));
        // SVG glyph count is capped at MAX_GLYPHS.
        string memory svg = _extractSvgFromJson(json);
        assertEq(_countOccurrences(svg, ">+<"), renderer.MAX_GLYPHS());
    }

    /// @dev escapeJSON correctness: for ANY token name, the rendered JSON must
    ///      contain no raw control byte (0x00-0x1F). The token name is
    ///      interpolated into the JSON `name` field via
    ///      `LibString.escapeJSON(t.name())` (LiquidityLayerSpriteRenderer.sol:77),
    ///      so the only path a control byte could reach the output is an
    ///      escaping failure. The description here is just buy/sell counts and
    ///      the image is base64 SVG (both printable), so the name is the
    ///      escaped field that carries arbitrary bytes — we set it via the
    ///      stub's constructor (`RenderableTokenStub.name()`).
    function testFuzz_contractURI_noRawControlBytes(string memory name_) public {
        // Fresh token carrying the fuzzed name; bind it to its own pool so the
        // counter extension resolves it (countsForToken returns 0/0).
        RenderableTokenStub fuzzToken = new RenderableTokenStub(name_, "FZ", "ipfs://fz");
        address paired = makeAddr("fuzzPaired");
        bool nmIsToken0 = uint160(address(fuzzToken)) < uint160(paired);
        PoolKey memory pkFuzz = PoolKey({
            currency0: Currency.wrap(nmIsToken0 ? address(fuzzToken) : paired),
            currency1: Currency.wrap(nmIsToken0 ? paired : address(fuzzToken)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
        vm.prank(hook);
        ext.initializePreLockerSetup(pkFuzz, nmIsToken0, "");

        bytes memory json = bytes(_decodeJsonUri(renderer.contractURI(address(fuzzToken))));
        for (uint256 i = 0; i < json.length; i++) {
            assertGe(uint8(json[i]), 0x20, "raw control byte in rendered JSON");
        }
    }

    // ─── String helpers ──────────────────────────────────────────────

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i = 0; i + n.length <= h.length; i++) {
            bool eq = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    eq = false;
                    break;
                }
            }
            if (eq) return true;
        }
        return false;
    }

    function _countOccurrences(string memory haystack, string memory needle)
        internal
        pure
        returns (uint256 c)
    {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return 0;
        for (uint256 i = 0; i + n.length <= h.length; i++) {
            bool eq = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    eq = false;
                    break;
                }
            }
            if (eq) {
                c++;
                i += n.length - 1;
            }
        }
    }

    function _countByteSequence(bytes memory h, bytes memory n) internal pure returns (uint256 c) {
        if (n.length == 0 || n.length > h.length) return 0;
        for (uint256 i = 0; i + n.length <= h.length; i++) {
            bool eq = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    eq = false;
                    break;
                }
            }
            if (eq) {
                c++;
                i += n.length - 1;
            }
        }
    }

    function _extractSvgFromJson(string memory json) internal pure returns (string memory) {
        // Find the substring after `"image":"data:image/svg+xml;base64,` and before the next `"`.
        bytes memory b = bytes(json);
        bytes memory marker = bytes('"image":"data:image/svg+xml;base64,');
        uint256 start = type(uint256).max;
        for (uint256 i = 0; i + marker.length <= b.length; i++) {
            bool eq = true;
            for (uint256 j = 0; j < marker.length; j++) {
                if (b[i + j] != marker[j]) {
                    eq = false;
                    break;
                }
            }
            if (eq) {
                start = i + marker.length;
                break;
            }
        }
        require(start != type(uint256).max, "image marker not found");
        // find closing quote
        uint256 end = start;
        while (end < b.length && b[end] != '"') end++;
        bytes memory payload = new bytes(end - start);
        for (uint256 i = 0; i < payload.length; i++) {
            payload[i] = b[start + i];
        }
        return string(Base64.decode(string(payload)));
    }

    function _toLowerHex(address a) internal pure returns (string memory) {
        bytes memory hexChars = "0123456789abcdef";
        bytes memory out = new bytes(42);
        out[0] = "0";
        out[1] = "x";
        uint160 v = uint160(a);
        for (uint256 i = 0; i < 20; i++) {
            uint8 byteVal = uint8(v >> ((19 - i) * 8));
            out[2 + i * 2] = hexChars[byteVal >> 4];
            out[2 + i * 2 + 1] = hexChars[byteVal & 0x0f];
        }
        return string(out);
    }
}
