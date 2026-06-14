// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {
    LiquidityLayerCounterPoolExtension
} from "../src/extensions/LiquidityLayerCounterPoolExtension.sol";
import {LiquidityLayerOnchainRenderer} from "../src/extensions/LiquidityLayerOnchainRenderer.sol";
import {IScriptyBuilderV2, IScriptyStorageV2} from "../src/interfaces/IScripty.sol";
import {MockScriptyStorage} from "../test/mocks/MockScriptyStorage.sol";

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Stub renderable token with `name()` / `symbol()` getters.
contract MinimalRenderableToken {
    string public name;
    string public symbol;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }
}

/// @notice Renders a real `LiquidityLayerOnchainRenderer.contractURI(token)` against
///         the canonical mainnet ScriptyBuilderV2 (via fork) and a locally deployed
///         MockScriptyStorage preloaded with a placeholder sketch + tiny PNG.
///
///         Writes the resulting JSON data URI to `tmp/onchain-animation.uri.txt`.
///         Decode it to a real `.html` file with `script-js/decode-animation-url.mjs`.
///
/// Usage:
///     forge script script/PreviewLLAnimation.s.sol:PreviewLLAnimation \
///         --fork-url "$MAINNET_RPC_URL" -vv
contract PreviewLLAnimation is Script {
    address constant SCRIPTY_BUILDER = 0xD7587F110E08F4D120A231bA97d3B577A81Df022;

    string constant SKETCH_NAME = "ll/sketch.preview";
    string constant MONA_NAME = "ll/mona.preview";
    string constant MONA_MIME = "image/png";

    string constant OUT_PATH = "tmp/onchain-animation.uri.txt";
    uint256 constant N_TRADES = 100;

    function run() public {
        address deployer = makeAddr("ll-preview-deployer");
        vm.startPrank(deployer, deployer);

        // 1. Mock storage, preloaded with sketch + tiny placeholder PNG.
        MockScriptyStorage storage_ = new MockScriptyStorage();
        // Sketch is referenced via tagType 2 (`<script src="data:text/javascript;base64,...">`).
        // ScriptyBuilder embeds storage bytes verbatim into the src attr, so storage must
        // hold the already-base64-encoded JS — same pattern production sketches use.
        storage_.set(SKETCH_NAME, bytes(Base64.encode(bytes(_sketchJs()))));
        storage_.set(MONA_NAME, _placeholderPng());

        // 2. Counter — deployer plays the hook role so we can drive afterSwap.
        LiquidityLayerCounterPoolExtension counter =
            new LiquidityLayerCounterPoolExtension(deployer);

        // 3. Token + pool key. Sort token vs paired so we can set artCoinIsToken0
        //    correctly and not depend on address luck.
        MinimalRenderableToken token = new MinimalRenderableToken("LL Preview", "LLP");
        address paired = address(0x0123456789abcDEF0123456789abCDef01234567);
        bool tokenIsToken0 = uint160(address(token)) < uint160(paired);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(tokenIsToken0 ? address(token) : paired),
            currency1: Currency.wrap(tokenIsToken0 ? paired : address(token)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(deployer)
        });
        counter.initializePreLockerSetup(key, tokenIsToken0, "");

        // 4. Drive a deterministic mix of buys/sells.
        for (uint256 i = 0; i < N_TRADES; i++) {
            bool isBuy = uint256(keccak256(abi.encode(address(token), i))) & 1 == 1;
            bool zeroForOne = isBuy != tokenIsToken0;
            counter.afterSwap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: zeroForOne, amountSpecified: -1 ether, sqrtPriceLimitX96: 0
                }),
                toBalanceDelta(0, 0),
                tokenIsToken0,
                ""
            );
        }

        // 5. Renderer wired to the real Builder + our mock storage.
        LiquidityLayerOnchainRenderer renderer = new LiquidityLayerOnchainRenderer(
            deployer,
            counter,
            IScriptyBuilderV2(SCRIPTY_BUILDER),
            IScriptyStorageV2(address(storage_)),
            SKETCH_NAME,
            MONA_NAME,
            MONA_MIME,
            "Liquidity Layer preview render"
        );

        // 6. Read & dump.
        (uint128 buys, uint128 sells) = counter.countsForToken(address(token));
        console2.log("buys :", buys);
        console2.log("sells:", sells);
        console2.log("total:", uint256(buys) + uint256(sells));

        string memory uri = renderer.contractURI(address(token));
        console2.log("contractURI length:", bytes(uri).length);

        vm.writeFile(OUT_PATH, uri);
        console2.log("wrote URI to:", OUT_PATH);

        vm.stopPrank();
    }

    /// Tiny placeholder canvas sketch. Reads LL_TOTAL/LL_BITS/LL_SEED + the
    /// shimmed window.LL_ASSETS.mona, draws colored dots over the background.
    function _sketchJs() internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                "(()=>{",
                "const c=document.createElement('canvas');c.width=1000;c.height=1000;",
                "document.body.style.margin='0';document.body.appendChild(c);",
                "const ctx=c.getContext('2d');",
                "const img=new Image();img.onload=()=>{",
                "ctx.fillStyle='#222';ctx.fillRect(0,0,1000,1000);",
                "ctx.drawImage(img,0,0,1000,1000);",
                "const bits=atob(LL_BITS);",
                "const seed=BigInt(LL_SEED);",
                "for(let i=0;i<LL_TOTAL;i++){",
                "const bit=(bits.charCodeAt(i>>3)>>(i&7))&1;",
                "const h=seed^BigInt(i*1000003);",
                "const x=Number(((h*1103515245n)>>11n)%1000n);",
                "const y=Number(((h*2654435761n)>>13n)%1000n);",
                "ctx.fillStyle=bit?'#22c55e':'#ef4444';",
                "ctx.beginPath();ctx.arc(x,y,8,0,6.283);ctx.fill();",
                "}",
                "ctx.fillStyle='#fff';ctx.font='20px monospace';",
                "ctx.fillText('LL_TOTAL='+LL_TOTAL,12,28);",
                "ctx.fillText('LL_SEED='+LL_SEED.slice(0,18)+'...',12,52);",
                "};img.onerror=()=>{",
                "ctx.fillStyle='#222';ctx.fillRect(0,0,1000,1000);",
                "ctx.fillStyle='#fff';ctx.font='20px monospace';",
                "ctx.fillText('image failed to load',12,28);",
                "};img.src=window.LL_ASSETS.mona;",
                "})();"
            )
        );
    }

    /// Smallest valid 1x1 transparent PNG (67 bytes).
    function _placeholderPng() internal pure returns (bytes memory) {
        return hex"89504E470D0A1A0A0000000D49484452000000010000000108060000001F15C4890000000D49444154789C6300010000050001"
            hex"0D0A2DB40000000049454E44AE426082";
    }
}
