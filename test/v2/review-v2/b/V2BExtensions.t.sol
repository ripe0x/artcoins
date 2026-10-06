// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// independent review v2-b: extension claims that hold (no fork needed).

import {Test} from "forge-std/Test.sol";

import {ArtCoinsAirdropV2} from "../../../../src/v2/extensions/ArtCoinsAirdropV2.sol";
import {ArtCoinsVaultV2} from "../../../../src/v2/extensions/ArtCoinsVaultV2.sol";
import {IArtCoinsAirdropV2} from "../../../../src/v2/extensions/interfaces/IArtCoinsAirdropV2.sol";
import {IArtCoinsVaultV2} from "../../../../src/v2/extensions/interfaces/IArtCoinsVaultV2.sol";
import {IArtCoinsFactoryV2} from "../../../../src/v2/interfaces/IArtCoinsFactoryV2.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract V2BCoin is ERC20 {
    constructor() ERC20("c", "C") {
        _mint(msg.sender, 1e30);
    }
}

contract V2BExtensionsTest is Test {
    // vector from ui/node_modules/@openzeppelin/merkle-tree StandardMerkleTree.of(
    //   [[0x11..11, 1000e18], [0x22..22, 2500e18], [0x33..33, 42]], ["address","uint256"])
    // the same call ui/src/lib/merkle.ts buildTree makes.
    bytes32 internal constant ROOT =
        0xa25312279267352059d2ad647c87c163e44357aefb68c3cf2beaa679e277261d;
    address internal constant A = 0x1111111111111111111111111111111111111111;
    address internal constant C = 0x3333333333333333333333333333333333333333;

    V2BCoin internal coin;
    ArtCoinsAirdropV2 internal air;
    ArtCoinsVaultV2 internal vault;
    PoolKey internal key;

    function setUp() public {
        vm.warp(1_800_000_000);
        coin = new V2BCoin();
        air = new ArtCoinsAirdropV2(address(this));
        vault = new ArtCoinsVaultV2(address(this));
        coin.approve(address(air), type(uint256).max);
        coin.approve(address(vault), type(uint256).max);
    }

    function _cfg(address ext, bytes memory data)
        internal
        pure
        returns (IArtCoinsFactoryV2.DeploymentConfigV2 memory c)
    {
        c.extensions = new IArtCoinsFactoryV2.ExtensionConfigV2[](1);
        c.extensions[0] = IArtCoinsFactoryV2.ExtensionConfigV2({
            extension: ext, msgValue: 0, extensionBps: 100, extensionData: data
        });
    }

    function _proofA() internal pure returns (bytes32[] memory p) {
        p = new bytes32[](2);
        p[0] = 0x72b368ad0596ce9c713617da08373230fee08b9c8592ccc108f496d2585eca14;
        p[1] = 0xe17e2469047adc6db21d0ec305f3d9cb275607495e7ef0363a7609b1e77073ae;
    }

    function _proofC() internal pure returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = 0x1b56d98ac230498959773c18e92fae8d28eb7be168a8162af1179c78ae9e1c4b;
    }

    /// js StandardMerkleTree proofs verify on chain; claim window edges are
    /// exact: last claim second is sweepTime - 1, sweep opens at sweepTime.
    function test_holds_airdrop_jsTreeVector_andWindowEdges() public {
        air.receiveTokens(
            _cfg(address(air), abi.encode(address(0xBEEF), ROOT, uint256(0), uint256(100))),
            key,
            address(coin),
            4000e18,
            0
        );
        IArtCoinsAirdropV2.Tranche memory t = air.tranche(address(coin), 0);
        // lockup 0: claimable from the launch second, linear over 100 s
        vm.warp(t.lockupEnd + 50);
        air.claim(address(coin), 0, A, 1000e18, _proofA());
        assertEq(coin.balanceOf(A), 500e18);
        // wrong amount for a valid address fails
        vm.expectRevert(IArtCoinsAirdropV2.InvalidProof.selector);
        air.claim(address(coin), 0, A, 1001e18, _proofA());

        vm.warp(t.sweepTime - 1);
        air.claim(address(coin), 0, C, 42, _proofC());
        assertEq(coin.balanceOf(C), 42);
        vm.expectRevert(IArtCoinsAirdropV2.SweepNotReady.selector);
        air.sweep(address(coin), 0);

        vm.warp(t.sweepTime);
        vm.expectRevert(IArtCoinsAirdropV2.ClaimWindowClosed.selector);
        air.claim(address(coin), 0, A, 1000e18, _proofA());
        air.sweep(address(coin), 0);
        assertEq(coin.balanceOf(address(0xBEEF)), 4000e18 - 500e18 - 42);
    }

    /// cliff: nothing at lockupEnd, 1 wei granularity right after, all at vestingEnd.
    function test_holds_vault_cliffEdges() public {
        uint256 amt = 90 days; // 1 wei per second of vesting
        vault.receiveTokens(
            _cfg(address(vault), abi.encode(address(0xCAFE), uint256(7 days), uint256(90 days))),
            key,
            address(coin),
            amt,
            0
        );
        IArtCoinsVaultV2.Allocation memory a = vault.allocation(address(coin), 0);
        vm.warp(a.lockupEndTime - 1);
        vm.expectRevert(IArtCoinsVaultV2.AllocationNotUnlocked.selector);
        vault.claim(address(coin), 0);
        vm.warp(a.lockupEndTime);
        vm.expectRevert(IArtCoinsVaultV2.NoBalanceToClaim.selector);
        vault.claim(address(coin), 0);
        vm.warp(a.lockupEndTime + 1);
        vault.claim(address(coin), 0);
        assertEq(coin.balanceOf(address(0xCAFE)), 1);
        vm.warp(a.vestingEndTime);
        vault.claim(address(coin), 0);
        assertEq(coin.balanceOf(address(0xCAFE)), amt);
    }
}
