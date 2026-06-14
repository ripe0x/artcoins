// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BurnExtension} from "../src/extensions/BurnExtension.sol";
import {IArtCoinsExtension} from "../src/interfaces/IArtCoinsExtension.sol";
import {IArtCoinsFactory} from "../src/interfaces/IArtCoinsFactory.sol";
import {Test} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @dev Mintable + burnable test token.
contract MockBurnableToken is ERC20, ERC20Burnable {
    constructor() ERC20("Mock", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract BurnExtensionTest is Test {
    BurnExtension internal ext;
    MockBurnableToken internal token;
    address internal factory = address(0xF1);

    PoolKey internal emptyKey = PoolKey({
        currency0: Currency.wrap(address(0)),
        currency1: Currency.wrap(address(0)),
        fee: 0,
        tickSpacing: 0,
        hooks: IHooks(address(0))
    });

    function setUp() public {
        ext = new BurnExtension(factory);
        token = new MockBurnableToken();
    }

    function _makeConfig() internal view returns (IArtCoinsFactory.DeploymentConfig memory dc) {
        // Empty config; the extension only reads its own slot of extensionConfigs[0].
        IArtCoinsFactory.ExtensionConfig[] memory extConfigs =
            new IArtCoinsFactory.ExtensionConfig[](1);
        extConfigs[0] = IArtCoinsFactory.ExtensionConfig({
            extension: address(ext), msgValue: 0, extensionBps: 2602, extensionData: ""
        });
        dc.extensionConfigs = extConfigs;
    }

    function test_burnsExactSupplyFromFactory() public {
        uint256 amount = 260_200_000e18;
        token.mint(factory, amount);

        // Factory pre-approves extension before calling.
        vm.prank(factory);
        token.approve(address(ext), amount);

        uint256 supplyBefore = token.totalSupply();

        IArtCoinsFactory.DeploymentConfig memory dc = _makeConfig();
        vm.prank(factory);
        ext.receiveTokens(dc, emptyKey, address(token), amount, 0);

        assertEq(token.totalSupply(), supplyBefore - amount);
        assertEq(token.balanceOf(address(ext)), 0);
        assertEq(token.balanceOf(factory), 0);
    }

    function test_revertsOnNonFactoryCaller() public {
        token.mint(address(this), 100);
        token.approve(address(ext), 100);
        IArtCoinsFactory.DeploymentConfig memory dc = _makeConfig();

        vm.expectRevert(BurnExtension.Unauthorized.selector);
        ext.receiveTokens(dc, emptyKey, address(token), 100, 0);
    }

    function test_revertsOnNonzeroMsgValue() public {
        vm.deal(factory, 1 ether);
        IArtCoinsFactory.DeploymentConfig memory dc = _makeConfig();
        vm.prank(factory);
        vm.expectRevert(BurnExtension.UnexpectedMsgValue.selector);
        ext.receiveTokens{value: 1 ether}(dc, emptyKey, address(token), 100, 0);
    }

    function test_revertsOnZeroSupply() public {
        IArtCoinsFactory.DeploymentConfig memory dc = _makeConfig();
        vm.prank(factory);
        vm.expectRevert(BurnExtension.ZeroSupply.selector);
        ext.receiveTokens(dc, emptyKey, address(token), 0, 0);
    }

    function test_supportsInterface() public view {
        assertTrue(ext.supportsInterface(type(IArtCoinsExtension).interfaceId));
        assertTrue(ext.supportsInterface(0x01ffc9a7)); // IERC165
        assertFalse(ext.supportsInterface(bytes4(0xdeadbeef)));
    }
}
