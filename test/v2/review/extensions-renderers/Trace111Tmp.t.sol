// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
interface I { function contractURI() external view returns (string memory); }
contract Trace111Tmp is Test {
    function setUp() public { vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://mainnet.gateway.tenderly.co"))); }
    function test_trace() public view { I(0x61C9d89fe1212F6b55fF888816A151463287B8ae).contractURI(); }
}
