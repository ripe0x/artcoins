// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Fork proofs: gas of the LIVE LAYER and coin 111 metadata paths, and how the
// live LAYER renderer scales with the trade counter. Read only.

import {Test, console2} from "forge-std/Test.sol";

interface ITokenURI {
    function contractURI() external view returns (string memory);
    function tokenURI() external view returns (string memory);
    function metadataRenderer() external view returns (address);
}

interface ILLRenderer {
    function counter() external view returns (address);
}

interface ICounter {
    function poolForToken(address) external view returns (bytes32);
    function totalTrades(bytes32) external view returns (uint256);
}

contract ForkRenderersReviewTest is Test {
    address constant LAYER = 0xb7287e4A5b605aB92A8589C62af8A4ebD347E6c9;
    address constant COIN_111 = 0x61C9d89fe1212F6b55fF888816A151463287B8ae;

    function setUp() public {
        vm.createSelectFork(
            vm.envOr("MAINNET_RPC_URL", string("https://mainnet.gateway.tenderly.co"))
        );
    }

    function _gas(address t) internal view returns (uint256 used, uint256 len) {
        uint256 g = gasleft();
        string memory s = ITokenURI(t).contractURI();
        used = g - gasleft();
        len = bytes(s).length;
    }

    function test_measure_G4_liveLayerAnd111() public view {
        (uint256 gl, uint256 ll) = _gas(LAYER);
        (uint256 g1, uint256 l1) = _gas(COIN_111);
        console2.log("LAYER renderer", ITokenURI(LAYER).metadataRenderer());
        console2.log("  LAYER contractURI gas / bytes", gl, ll);
        console2.log("111 renderer", ITokenURI(COIN_111).metadataRenderer());
        console2.log("  111 contractURI gas / bytes", g1, l1);
    }

    /// @dev Live LAYER renderer + real ScriptyBuilderV2 + real stored assets,
    ///      with the live counter's trade total forced upward. The live counter
    ///      is LiquidityLayerAutoForwardExtension (Ownable: _owner slot 0,
    ///      _counts slot 1).
    function test_bug_G2_liveLayerRendererExceeds50MGasAsTradesGrow() public {
        address r = ITokenURI(LAYER).metadataRenderer();
        address c = ILLRenderer(r).counter();
        bytes32 pid = ICounter(c).poolForToken(LAYER);
        uint256 live = ICounter(c).totalTrades(pid);
        console2.log("live trades", live);
        bytes32 slot = keccak256(abi.encode(pid, uint256(1)));
        uint256[5] memory ns = [uint256(10_000), 100_000, 250_000, 500_000, 1_000_000];
        uint256 crossed;
        for (uint256 i = 0; i < ns.length; i++) {
            vm.store(c, slot, bytes32(((ns[i] / 2) << 128) | (ns[i] - ns[i] / 2)));
            assertEq(ICounter(c).totalTrades(pid), ns[i], "slot layout");
            (uint256 g, uint256 l) = _gas(LAYER);
            console2.log("forced trades", ns[i]);
            console2.log("  gas / bytes", g, l);
            if (crossed == 0 && g > 50_000_000) crossed = ns[i];
        }
        console2.log("first sample over 50M:", crossed);
        assertGt(crossed, 0, "never crossed 50M");
    }
}
