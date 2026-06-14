// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ArtCoinsToken} from "../src/ArtCoinsToken.sol";
import {IArtCoinsFactory} from "../src/interfaces/IArtCoinsFactory.sol";
import {ArtCoinsDeployer} from "../src/utils/ArtCoinsDeployer.sol";
import {Test} from "forge-std/Test.sol";

contract ArtCoinsDeployerTest is Test {
    uint256 constant SUPPLY = 100_000_000_000e18;
    address constant ADMIN = address(0xA1);

    function _makeConfig(bytes32 salt) internal pure returns (IArtCoinsFactory.TokenConfig memory) {
        return IArtCoinsFactory.TokenConfig({
            tokenAdmin: ADMIN,
            name: "Test",
            symbol: "TST",
            salt: salt,
            image: "https://img.com/test.png",
            metadata: "test desc",
            context: "ctx",
            totalSupply: 0,
            renderer: address(0)
        });
    }

    function test_deployToken_createsToken() public {
        IArtCoinsFactory.TokenConfig memory config = _makeConfig(bytes32(uint256(1)));
        address tokenAddr = ArtCoinsDeployer.deployToken(config, SUPPLY);

        assertTrue(tokenAddr != address(0));

        ArtCoinsToken token = ArtCoinsToken(tokenAddr);
        assertEq(token.name(), "Test");
        assertEq(token.symbol(), "TST");
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.admin(), ADMIN);
        assertEq(token.originalAdmin(), ADMIN);
        assertEq(token.imageUrl(), "https://img.com/test.png");
        assertEq(token.metadata(), "test desc");
        assertEq(token.context(), "ctx");
    }

    function test_deployToken_deterministicAddress() public {
        IArtCoinsFactory.TokenConfig memory config = _makeConfig(bytes32(uint256(42)));
        address addr1 = ArtCoinsDeployer.deployToken(config, SUPPLY);

        IArtCoinsFactory.TokenConfig memory config2 = _makeConfig(bytes32(uint256(43)));
        address addr2 = ArtCoinsDeployer.deployToken(config2, SUPPLY);

        assertTrue(addr1 != addr2);
    }

    function test_deployToken_sameSaltSameAdminReverts() public {
        IArtCoinsFactory.TokenConfig memory config = _makeConfig(bytes32(uint256(99)));
        ArtCoinsDeployer.deployToken(config, SUPPLY);

        // CREATE2 collision on retry
        vm.expectRevert();
        ArtCoinsDeployer.deployToken(config, SUPPLY);
    }

    function test_deployToken_erc20Functions() public {
        IArtCoinsFactory.TokenConfig memory config = _makeConfig(bytes32(uint256(100)));
        address tokenAddr = ArtCoinsDeployer.deployToken(config, SUPPLY);
        ArtCoinsToken token = ArtCoinsToken(tokenAddr);

        token.transfer(address(0xBEEF), 1000e18);
        assertEq(token.balanceOf(address(0xBEEF)), 1000e18);

        token.burn(500e18);
        assertEq(token.totalSupply(), SUPPLY - 500e18);
    }
}
