// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {
    LiquidityLayerCounterPoolExtension
} from "../src/extensions/LiquidityLayerCounterPoolExtension.sol";
import {LiquidityLayerOnchainRenderer} from "../src/extensions/LiquidityLayerOnchainRenderer.sol";
import {IScriptyBuilderV2, IScriptyStorageV2} from "../src/interfaces/IScripty.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Stub minimal token for renderer testing.
contract MinimalRenderableToken {
    string public name;
    string public symbol;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }
}

/// @notice End-to-end fork verification for LiquidityLayerOnchainRenderer.
///
///     1. Deploy a fresh standalone counter we fully control (impersonate
///        ourselves as the hook so we can drive afterSwap directly).
///     2. Register a stub renderable token in the counter.
///     3. Drive 100 fake trades (mixed buys/sells) through afterSwap.
///     4. Deploy the renderer pointing at the standalone counter + the
///        ScriptyStorage entries we uploaded earlier.
///     5. Call contractURI(token) — this exercises the real ScriptyBuilderV2
///        on the forked chain.
///     6. Decode the JSON, extract the animation_url HTML data URI, write
///        the decoded HTML to disk so puppeteer can browser-test it.
///
/// Required env vars:
///     PRIVATE_KEY          deployer / hook impersonator
///     LL_SKETCH_NAME       must already exist in scripty (e.g. "ll/sketch.v1")
///     LL_MONA_NAME         must already exist (e.g. "ll/mona.v1")
///     LL_MONA_MIME         MIME for the mona bytes (e.g. "image/jpeg")
///     LL_DESCRIPTION       description string
///     LL_OUT_HTML_PATH     output filesystem path for the assembled HTML
contract VerifyLLRenderer is Script {
    address constant SCRIPTY_BUILDER = 0xD7587F110E08F4D120A231bA97d3B577A81Df022;
    address constant SCRIPTY_STORAGE = 0xbD11994aABB55Da86DC246EBB17C1Be0af5b7699;

    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        string memory sketchName = vm.envString("LL_SKETCH_NAME");
        string memory monaName = vm.envString("LL_MONA_NAME");
        string memory monaMime = vm.envString("LL_MONA_MIME");
        string memory description = vm.envString("LL_DESCRIPTION");
        string memory outPath = vm.envString("LL_OUT_HTML_PATH");

        // Step 1+2+3: counter + token + simulated trades. The counter expects
        // a hook to call afterSwap, so we deploy with deployer as hook and
        // drive trades directly.
        vm.startBroadcast(pk);
        LiquidityLayerCounterPoolExtension counter =
            new LiquidityLayerCounterPoolExtension(deployer);
        MinimalRenderableToken token = new MinimalRenderableToken("LL Test", "LLT");

        // Build a pool key with our token at currency0 (sort by address).
        address paired = address(0x0123456789abcDEF0123456789abCDef01234567);
        bool tokenIsToken0 = uint160(address(token)) < uint160(paired);
        PoolKey memory pk_ = PoolKey({
            currency0: Currency.wrap(tokenIsToken0 ? address(token) : paired),
            currency1: Currency.wrap(tokenIsToken0 ? paired : address(token)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(deployer)
        });

        counter.initializePreLockerSetup(pk_, tokenIsToken0, "");

        // Pseudo-random buy/sell pattern (deterministic from token addr).
        uint256 nTrades = 100;
        for (uint256 i = 0; i < nTrades; i++) {
            bool isBuy = uint256(keccak256(abi.encode(address(token), i))) & 1 == 1;
            bool zeroForOne = isBuy != tokenIsToken0;
            counter.afterSwap(
                pk_,
                IPoolManager.SwapParams({
                    zeroForOne: zeroForOne, amountSpecified: -1 ether, sqrtPriceLimitX96: 0
                }),
                toBalanceDelta(0, 0),
                tokenIsToken0,
                ""
            );
        }

        // Step 4: deploy renderer.
        LiquidityLayerOnchainRenderer renderer = new LiquidityLayerOnchainRenderer(
            deployer,
            counter,
            IScriptyBuilderV2(SCRIPTY_BUILDER),
            IScriptyStorageV2(SCRIPTY_STORAGE),
            sketchName,
            monaName,
            monaMime,
            description
        );
        vm.stopBroadcast();

        // Step 5: read contractURI and report counts.
        (uint128 buys, uint128 sells) = counter.countsForToken(address(token));
        console2.log("counter buys:", buys);
        console2.log("counter sells:", sells);
        console2.log("counter total:", uint256(buys) + uint256(sells));
        console2.log("renderer:", address(renderer));
        console2.log("token:   ", address(token));

        string memory uri = renderer.contractURI(address(token));
        console2.log("contractURI length:", bytes(uri).length);

        // Step 6: extract the animation_url data URI's HTML payload and
        // dump to disk. We do this in a Node post-process step (foundry
        // can't easily do base64 decode of a substring), so just write
        // the full JSON URI and let the caller decode it.
        vm.writeFile(outPath, uri);
        console2.log("wrote contractURI to:", outPath);
    }
}
