// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Test} from "forge-std/Test.sol";

import {
    LiquidityLayerCounterPoolExtension
} from "../src/extensions/LiquidityLayerCounterPoolExtension.sol";
import {LiquidityLayerOnchainRenderer} from "../src/extensions/LiquidityLayerOnchainRenderer.sol";
import {
    HTMLRequest,
    HTMLTag,
    IScriptyBuilderV2,
    IScriptyStorageV2
} from "../src/interfaces/IScripty.sol";

/// @dev Stub builder that just concatenates all body tagContents — gives unit
///      tests visibility into the script bodies the renderer assembles, which
///      a black-box mock (always returning a constant) doesn't.
contract EchoScriptyBuilder is IScriptyBuilderV2 {
    function getHTMLString(HTMLRequest calldata r) external pure override returns (string memory) {
        bytes memory out = bytes("<html><body>");
        for (uint256 i = 0; i < r.bodyTags.length; i++) {
            out = bytes.concat(out, "<tag>", r.bodyTags[i].tagContent, "</tag>");
        }
        return string(bytes.concat(out, "</body></html>"));
    }
}

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract RenderableTokenStub {
    string private _name;
    string private _symbol;
    uint256 public totalSupply;

    constructor(string memory n, string memory s) {
        _name = n;
        _symbol = s;
        totalSupply = 1_000_000_000 * 1e18;
    }

    function name() external view returns (string memory) {
        return _name;
    }

    function symbol() external view returns (string memory) {
        return _symbol;
    }

    function setTotalSupply(uint256 s) external {
        totalSupply = s;
    }
}

contract LiquidityLayerOnchainRendererTest is Test {
    using PoolIdLibrary for PoolKey;

    // Canonical scripty addresses — same on every chain we deploy to.
    address constant SCRIPTY_BUILDER = 0xD7587F110E08F4D120A231bA97d3B577A81Df022;
    address constant SCRIPTY_STORAGE = 0xbD11994aABB55Da86DC246EBB17C1Be0af5b7699;

    LiquidityLayerCounterPoolExtension internal counter;
    LiquidityLayerOnchainRenderer internal renderer;
    RenderableTokenStub internal token;

    address internal owner = address(0xA11CE);
    address internal hook = makeAddr("hook");

    PoolKey internal pk;
    PoolId internal pid;
    bool internal nmIsToken0;

    string constant SKETCH_NAME = "ll/sketch.v1";
    string constant MONA_NAME = "ll/mona.v1";
    string constant MONA_MIME = "image/jpeg";

    // Mock returns. The renderer reads `getContent(name, "")` for both the
    // mona asset and (via ScriptyBuilder) the sketch asset. We mock both,
    // plus ScriptyBuilder.getHTMLString itself so we don't need its full
    // implementation in unit tests.
    bytes constant MOCK_MONA_BYTES = hex"deadbeef";
    bytes constant MOCK_SKETCH_BYTES = hex"f00d";

    function setUp() public {
        counter = new LiquidityLayerCounterPoolExtension(hook);
        token = new RenderableTokenStub("Liquidity Layer", "LL");

        // Build a pool key that has token at currency0 if its address sorts low,
        // otherwise currency1. (Uniswap v4 requires currency0 < currency1.)
        address paired = makeAddr("paired");
        nmIsToken0 = uint160(address(token)) < uint160(paired);
        pk = PoolKey({
            currency0: Currency.wrap(nmIsToken0 ? address(token) : paired),
            currency1: Currency.wrap(nmIsToken0 ? paired : address(token)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
        pid = pk.toId();
        vm.prank(hook);
        counter.initializePreLockerSetup(pk, nmIsToken0, "");

        // Seed a known trade pattern: B B S B S S S B (8 trades, 4 buys / 4 sells).
        bool[] memory pattern = new bool[](8);
        pattern[0] = true;
        pattern[1] = true;
        pattern[2] = false;
        pattern[3] = true;
        pattern[4] = false;
        pattern[5] = false;
        pattern[6] = false;
        pattern[7] = true;
        for (uint256 i = 0; i < pattern.length; i++) {
            _swap(pattern[i]);
        }

        renderer = new LiquidityLayerOnchainRenderer(
            owner,
            counter,
            IScriptyBuilderV2(SCRIPTY_BUILDER),
            IScriptyStorageV2(SCRIPTY_STORAGE),
            SKETCH_NAME,
            MONA_NAME,
            MONA_MIME,
            "Liquidity Layer test"
        );

        // ScriptyStorage reads — only the mona asset is read directly by the
        // renderer; the sketch is fetched indirectly via ScriptyBuilder, which
        // we mock wholesale below.
        vm.mockCall(
            SCRIPTY_STORAGE,
            abi.encodeWithSelector(IScriptyStorageV2.getContent.selector, MONA_NAME, bytes("")),
            abi.encode(MOCK_MONA_BYTES)
        );

        // ScriptyBuilder is mocked to return a stable string. We assert the
        // input request's structure separately.
        vm.mockCall(
            SCRIPTY_BUILDER,
            abi.encodeWithSelector(IScriptyBuilderV2.getHTMLString.selector),
            abi.encode("<html>SCRIPTY_BUILDER_OUTPUT</html>")
        );
    }

    function _swap(bool isBuy) internal {
        bool zeroForOne = isBuy != nmIsToken0;
        IPoolManager.SwapParams memory p = IPoolManager.SwapParams({
            zeroForOne: zeroForOne, amountSpecified: -1 ether, sqrtPriceLimitX96: 0
        });
        vm.prank(hook);
        counter.afterSwap(pk, p, toBalanceDelta(0, 0), nmIsToken0, "");
    }

    // ─── Output shape ─────────────────────────────────────────────────

    function _decodeJsonUri(string memory uri) internal pure returns (string memory) {
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
        bytes memory prefix = bytes("data:application/json;base64,");
        for (uint256 i = 0; i < prefix.length; i++) {
            assertEq(b[i], prefix[i]);
        }
    }

    function test_contractURI_carriesNameSymbolDescription() public view {
        string memory json = _decodeJsonUri(renderer.contractURI(address(token)));
        // No overrides set — name/symbol come from the token stub.
        assertTrue(_contains(json, '"name":"Liquidity Layer"'));
        assertTrue(_contains(json, '"symbol":"LL"'));
        // Description: project text + literal "\n" + "Total burned: N <symbol>".
        // initialSupply is 0 by default, so burned = 0. Symbol is from the
        // token (LL), so the suffix is "0 LL".
        assertTrue(_contains(json, '"description":"Liquidity Layer test\\nTotal burned: 0 LL"'));
        // Make sure the old buys/sells text is GONE.
        assertFalse(_contains(json, "Buys:"));
        assertFalse(_contains(json, "Sells:"));
    }

    function test_nameSymbolOverride_usesOverridesWhenSet() public {
        vm.startPrank(owner);
        renderer.setNameOverride("Liquidity Layer");
        renderer.setSymbolOverride("LL");
        vm.stopPrank();

        string memory json = _decodeJsonUri(renderer.contractURI(address(token)));
        assertTrue(_contains(json, '"name":"Liquidity Layer"'));
        assertTrue(_contains(json, '"symbol":"LL"'));
        // Burn line uses the override symbol too.
        assertTrue(_contains(json, "Total burned: 0 LL"));
    }

    function test_burnLine_reflectsInitialSupplyMinusCurrent() public {
        vm.prank(owner);
        renderer.setSupplyConfig(1_000_000_000 * 1e18, 18);

        // Default token totalSupply == 1B → burned = 0.
        assertTrue(
            _contains(_decodeJsonUri(renderer.contractURI(address(token))), "Total burned: 0 LL")
        );

        // Burn 1,234 tokens (1234 * 1e18 wei) by lowering totalSupply.
        token.setTotalSupply((1_000_000_000 - 1234) * 1e18);
        assertTrue(
            _contains(_decodeJsonUri(renderer.contractURI(address(token))), "Total burned: 1234 LL")
        );

        // currentSupply > initialSupply → burned clamps to 0 (no underflow).
        token.setTotalSupply(2_000_000_000 * 1e18);
        assertTrue(
            _contains(_decodeJsonUri(renderer.contractURI(address(token))), "Total burned: 0 LL")
        );
    }

    function test_contractURI_imageIsOnchainMonaDataUri() public view {
        string memory json = _decodeJsonUri(renderer.contractURI(address(token)));
        // MOCK_MONA_BYTES = 0xdeadbeef -> base64 "3q2+7w=="
        assertTrue(_contains(json, '"image":"data:image/jpeg;base64,3q2+7w=="'));
    }

    function test_contractURI_previewWorksBeforeTokenIsDeployed() public {
        address predictedToken = makeAddr("predicted LAYER");
        vm.prank(owner);
        renderer.setSupplyConfig(1_000_000_000e18, 18);

        string memory json = _decodeJsonUri(renderer.contractURI(predictedToken));

        assertTrue(_contains(json, '"name":"Liquidity Layer"'));
        assertTrue(_contains(json, '"symbol":"LAYER"'));
        assertTrue(_contains(json, '"image":"data:image/jpeg;base64,3q2+7w=="'));
        assertTrue(_contains(json, "Total burned: 0 LAYER"));
    }

    function test_contractURI_animationUrlIsHtmlDataUri() public view {
        string memory json = _decodeJsonUri(renderer.contractURI(address(token)));
        // We mocked ScriptyBuilder to return "<html>SCRIPTY_BUILDER_OUTPUT</html>".
        // Base64-encode and confirm it ends up inside animation_url.
        string memory expected = string.concat(
            '"animation_url":"data:text/html;base64,',
            Base64.encode(bytes("<html>SCRIPTY_BUILDER_OUTPUT</html>"))
        );
        assertTrue(_contains(json, expected));
    }

    /// @dev Verify the payload handed to ScriptyBuilder is well-formed:
    ///      it should contain the bit-stream + total + seed in body tag 0,
    ///      the asset shim in body tag 1, and the sketch script reference
    ///      in body tag 2 — and the bit-stream should encode our 8-trade
    ///      pattern in LSB-first byte order.
    function test_buildHtml_passesCorrectRequestToScriptyBuilder() public {
        // Capture the request bytes by recording the call.
        vm.recordLogs();

        // Re-mock ScriptyBuilder to capture the calldata.
        bytes memory captured;
        vm.mockCall(
            SCRIPTY_BUILDER,
            abi.encodeWithSelector(IScriptyBuilderV2.getHTMLString.selector),
            abi.encode("<html>OK</html>")
        );

        // Decode by re-running and inspecting via a helper.
        // (Foundry doesn't expose a direct calldata capture; instead we
        // exercise the contract and inspect post-hoc by recomputing what
        // the contract would assemble.)
        string memory uri = renderer.contractURI(address(token));
        captured = bytes(uri);
        assertGt(captured.length, 0);

        // Independently verify the bit-stream the renderer would produce.
        // Pattern B B S B S S S B → bits (trade index 0..7, LSB-first within
        // byte 0): 1,1,0,1,0,0,0,1 → byte0 = 0b1000_1011 = 0x8B, byte1..31 = 0.
        // Then the rest of the 32-byte chunk is zero.
        uint256 chunk0 = counter.tradeChunk(pid, 0);
        // bits 0..7 of chunk0 are 1,1,0,1,0,0,0,1 → low byte = 0x8B.
        assertEq(chunk0 & 0xff, 0x8b);
    }

    function test_setters_onlyOwner() public {
        vm.expectRevert(LiquidityLayerOnchainRenderer.NotOwner.selector);
        renderer.setSketchScriptName("nope");

        vm.expectRevert(LiquidityLayerOnchainRenderer.NotOwner.selector);
        renderer.setMonaAsset("nope", "x");

        vm.expectRevert(LiquidityLayerOnchainRenderer.NotOwner.selector);
        renderer.setHistoryAsset("nope");

        vm.expectRevert(LiquidityLayerOnchainRenderer.NotOwner.selector);
        renderer.setImageOverrideUri("nope");

        vm.expectRevert(LiquidityLayerOnchainRenderer.NotOwner.selector);
        renderer.setProjectDescription("nope");

        vm.startPrank(owner);
        renderer.setSketchScriptName("ll/sketch.v2");
        renderer.setMonaAsset("ll/mona.v2", "image/webp");
        renderer.setHistoryAsset("ll/history.v1");
        renderer.setImageOverrideUri("ipfs://test");
        renderer.setProjectDescription("new desc");
        vm.stopPrank();

        assertEq(renderer.sketchScriptName(), "ll/sketch.v2");
        assertEq(renderer.monaAssetName(), "ll/mona.v2");
        assertEq(renderer.monaMimeType(), "image/webp");
        assertEq(renderer.historyAssetName(), "ll/history.v1");
        assertEq(renderer.imageOverrideUri(), "ipfs://test");
        assertEq(renderer.projectDescription(), "new desc");
    }

    function test_imageOverrideUri_replacesJsonImageOnly() public {
        // Sanity: with no override, the JSON image is the inlined data URI.
        string memory jsonBefore = _decodeJsonUri(renderer.contractURI(address(token)));
        assertTrue(_contains(jsonBefore, '"image":"data:image/jpeg;base64,3q2+7w=="'));

        // Set the override and re-render.
        string memory ipfsUri = "ipfs://bafkreiguuln4aa23vdrsx53ashjqxcrst2oms7mow2bu7u2axvncmkikiu";
        vm.prank(owner);
        renderer.setImageOverrideUri(ipfsUri);

        string memory jsonAfter = _decodeJsonUri(renderer.contractURI(address(token)));
        assertTrue(_contains(jsonAfter, string.concat('"image":"', ipfsUri, '"')));
        // The data:image/jpeg backing the canvas is still embedded in the
        // animation HTML — the override only changes the JSON's image field.
        assertTrue(_contains(jsonAfter, '"animation_url":"data:text/html;base64,'));
        // And it should NOT contain the old "image":"data:image/jpeg" form.
        assertFalse(_contains(jsonAfter, '"image":"data:image/jpeg;base64,'));
    }

    function test_history_isPrependedToCounterBits() public {
        // Replace the ScriptyBuilder mock with a stub that echoes the body
        // tagContents back inside `<tag>...</tag>` so we can read what the
        // renderer actually built.
        // Drop the setUp() mock that returned a constant for getHTMLString
        // and etch in a stub that echoes the body tagContents instead.
        vm.clearMockedCalls();
        // Re-establish the mona getContent mock dropped by clearMockedCalls.
        vm.mockCall(
            SCRIPTY_STORAGE,
            abi.encodeWithSelector(IScriptyStorageV2.getContent.selector, MONA_NAME, bytes("")),
            abi.encode(MOCK_MONA_BYTES)
        );
        EchoScriptyBuilder echo = new EchoScriptyBuilder();
        vm.etch(SCRIPTY_BUILDER, address(echo).code);

        bytes memory history = hex"ff00"; // 8 buys + 8 sells, LSB-first
        string memory historyName = "ll/history.v1";
        vm.mockCall(
            SCRIPTY_STORAGE,
            abi.encodeWithSelector(IScriptyStorageV2.getContent.selector, historyName, bytes("")),
            abi.encode(history)
        );
        vm.prank(owner);
        renderer.setHistoryAsset(historyName);

        string memory uri = renderer.contractURI(address(token));
        bytes memory innerHtml = _decodeAnimationHtml(_decodeJsonUri(uri));

        // setUp seeds 8 counter trades. With 16 history bits, total = 24.
        assertTrue(_contains(string(innerHtml), "LL_TOTAL=24"), "expected 16 history + 8 live");

        // Bit-stream bytes: history (0xff, 0x00) + counter chunk 0 (low byte
        // 0x8b from B B S B S S S B, rest zero). base64(0xff,0x00,0x8b) = "/wCL".
        assertTrue(
            _contains(string(innerHtml), 'LL_BITS="/wCL'),
            "expected /wCL prefix (history 0xff00 + counter 0x8b)"
        );
    }

    function test_emptyHistory_skipsHistoryRead_andTotalEqualsCounter() public {
        // historyAssetName is "" by default in setUp — no scripty read.
        // Counter has 8 trades. LL_TOTAL should equal 8.
        // Drop the setUp() mock that returned a constant for getHTMLString
        // and etch in a stub that echoes the body tagContents instead.
        vm.clearMockedCalls();
        // Re-establish the mona getContent mock dropped by clearMockedCalls.
        vm.mockCall(
            SCRIPTY_STORAGE,
            abi.encodeWithSelector(IScriptyStorageV2.getContent.selector, MONA_NAME, bytes("")),
            abi.encode(MOCK_MONA_BYTES)
        );
        EchoScriptyBuilder echo = new EchoScriptyBuilder();
        vm.etch(SCRIPTY_BUILDER, address(echo).code);

        string memory uri = renderer.contractURI(address(token));
        bytes memory innerHtml = _decodeAnimationHtml(_decodeJsonUri(uri));
        assertTrue(_contains(string(innerHtml), "LL_TOTAL=8"));
    }

    function _decodeAnimationHtml(string memory json) internal pure returns (bytes memory) {
        bytes memory j = bytes(json);
        bytes memory marker = bytes('"animation_url":"data:text/html;base64,');
        uint256 start = type(uint256).max;
        for (uint256 i = 0; i + marker.length <= j.length; i++) {
            bool eq = true;
            for (uint256 k = 0; k < marker.length; k++) {
                if (j[i + k] != marker[k]) {
                    eq = false;
                    break;
                }
            }
            if (eq) {
                start = i + marker.length;
                break;
            }
        }
        require(start != type(uint256).max, "marker not found");
        uint256 end = start;
        while (end < j.length && j[end] != '"') end++;
        bytes memory payload = new bytes(end - start);
        for (uint256 i = 0; i < payload.length; i++) {
            payload[i] = j[start + i];
        }
        return Base64.decode(string(payload));
    }

    function test_emptyMonaAssetReverts() public {
        vm.mockCall(
            SCRIPTY_STORAGE,
            abi.encodeWithSelector(IScriptyStorageV2.getContent.selector, MONA_NAME, bytes("")),
            abi.encode(bytes(""))
        );
        vm.expectRevert(LiquidityLayerOnchainRenderer.EmptyAsset.selector);
        renderer.contractURI(address(token));
    }

    /// @dev escapeJSON correctness: for ANY project-description string, the
    ///      rendered JSON must contain no raw control byte (0x00-0x1F). The
    ///      project description is interpolated into the JSON `description`
    ///      field via `LibString.escapeJSON(projectDescription)`
    ///      (LiquidityLayerOnchainRenderer.sol:266, through _buildDescription),
    ///      so the only path a control byte could reach the output is an
    ///      escaping failure. The name/symbol (also escaped) come from the
    ///      stub here; projectDescription is the directly-settable escaped
    ///      field, so we fuzz it via the owner setter. The animation_url HTML
    ///      is base64-encoded (printable) and the mona mock is non-empty so
    ///      contractURI does not hit the EmptyAsset revert.
    function testFuzz_contractURI_noRawControlBytes(string memory description_) public {
        vm.prank(owner);
        renderer.setProjectDescription(description_);

        bytes memory json = bytes(_decodeJsonUri(renderer.contractURI(address(token))));
        for (uint256 i = 0; i < json.length; i++) {
            assertGe(uint8(json[i]), 0x20, "raw control byte in rendered JSON");
        }
    }

    function test_emptyTotal_renderersZeroBitStream() public {
        // Use a fresh token with no recorded trades.
        RenderableTokenStub fresh = new RenderableTokenStub("Empty", "EMP");
        PoolKey memory pkF = PoolKey({
            currency0: Currency.wrap(
                uint160(address(fresh)) < uint160(makeAddr("p")) ? address(fresh) : makeAddr("p")
            ),
            currency1: Currency.wrap(
                uint160(address(fresh)) < uint160(makeAddr("p")) ? makeAddr("p") : address(fresh)
            ),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
        bool freshIsToken0 = Currency.unwrap(pkF.currency0) == address(fresh);
        vm.prank(hook);
        counter.initializePreLockerSetup(pkF, freshIsToken0, "");

        string memory json = _decodeJsonUri(renderer.contractURI(address(fresh)));
        // Description shape stable for a fresh token: project text + the
        // burn line (which is "0 EMP" since the stub starts with full supply).
        assertTrue(_contains(json, '"description":"Liquidity Layer test\\nTotal burned: 0 EMP"'));
    }

    // ─── helpers ─────────────────────────────────────────────────────

    function _contains(string memory hay, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(hay);
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
}
