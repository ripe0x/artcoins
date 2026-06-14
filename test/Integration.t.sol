// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test, console2} from "forge-std/Test.sol";

import {ArtCoinsFactory} from "../src/ArtCoinsFactory.sol";
import {ArtCoinsToken} from "../src/ArtCoinsToken.sol";
import {IArtCoinsFactory} from "../src/interfaces/IArtCoinsFactory.sol";
import {ArtCoinsFeeLocker} from "../src/legacy/ArtCoinsFeeLocker.sol";
import {DefaultMetadataRenderer} from "../src/renderer/DefaultMetadataRenderer.sol";
import {ArtCoinsDeployer} from "../src/utils/ArtCoinsDeployer.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Integration tests using a fork (mainnet or Sepolia)
/// @dev Run with:
///   Mainnet: forge test --match-contract IntegrationForkTest --fork-url $MAINNET_RPC_URL -vvv
///   Sepolia: forge test --match-contract IntegrationForkTest --fork-url $SEPOLIA_RPC_URL -vvv
contract IntegrationForkTest is Test {
    // Mainnet
    address constant MAINNET_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant MAINNET_POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Sepolia
    address constant SEPOLIA_POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address constant SEPOLIA_POSITION_MANAGER = 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4;
    address constant SEPOLIA_WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;

    // Shared
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // Resolved per-chain
    address public POOL_MANAGER;
    address public POSITION_MANAGER;
    address public WETH;

    ArtCoinsFactory public factory;
    ArtCoinsFeeLocker public feeLocker;
    DefaultMetadataRenderer public renderer;

    address public owner = address(0xCAFE);
    address public tokenAdmin = address(0xA1);

    uint256 constant TOKEN_SUPPLY = 100_000_000_000e18;

    bool _onFork;

    function setUp() public {
        // Detect chain and resolve addresses
        if (block.chainid == 1) {
            POOL_MANAGER = MAINNET_POOL_MANAGER;
            POSITION_MANAGER = MAINNET_POSITION_MANAGER;
            WETH = MAINNET_WETH;
        } else if (block.chainid == 11_155_111) {
            POOL_MANAGER = SEPOLIA_POOL_MANAGER;
            POSITION_MANAGER = SEPOLIA_POSITION_MANAGER;
            WETH = SEPOLIA_WETH;
        }

        // Skip if not on a supported fork
        if (POOL_MANAGER == address(0) || address(POOL_MANAGER).code.length == 0) {
            return;
        }
        _onFork = true;

        vm.startPrank(owner);

        // Deploy core infrastructure
        feeLocker = new ArtCoinsFeeLocker(owner);
        factory = new ArtCoinsFactory(owner);
        renderer = new DefaultMetadataRenderer();

        // Configure factory
        factory.setTeamFeeRecipient(owner);
        factory.setDeprecated(false);

        vm.stopPrank();
    }

    modifier onlyFork() {
        if (!_onFork) {
            console2.log("SKIPPING: No fork detected. Run with --fork-url (mainnet or Sepolia)");
            return;
        }
        _;
    }

    // ─── Factory deployment on fork ─────────────────────────────────────

    function test_fork_factoryDeployedCorrectly() public onlyFork {
        assertEq(factory.teamFeeRecipient(), owner);
        assertFalse(factory.deprecated());
    }

    function test_fork_poolManagerExists() public onlyFork {
        assertTrue(address(POOL_MANAGER).code.length > 0);
        assertTrue(address(POSITION_MANAGER).code.length > 0);
        assertTrue(address(PERMIT2).code.length > 0);
    }

    function test_fork_wethIsValid() public onlyFork {
        assertTrue(IERC20(WETH).totalSupply() > 0, "WETH has no supply");
    }

    // ─── Token proxy deployment on fork ─────────────────────────────────

    function test_fork_deployTokenProxy() public onlyFork {
        IArtCoinsFactory.TokenConfig memory config = IArtCoinsFactory.TokenConfig({
            tokenAdmin: tokenAdmin,
            name: "ForkTest Token",
            symbol: "FTK",
            salt: bytes32(uint256(block.timestamp)),
            image: "https://example.com/fork.png",
            metadata: "Fork test token",
            context: "integration test",
            totalSupply: 0,
            renderer: address(0)
        });

        address tokenAddr = ArtCoinsDeployer.deployToken(config, TOKEN_SUPPLY);

        ArtCoinsToken token = ArtCoinsToken(tokenAddr);

        assertEq(token.name(), "ForkTest Token");
        assertEq(token.symbol(), "FTK");
        assertEq(token.totalSupply(), TOKEN_SUPPLY);
        assertEq(token.admin(), tokenAdmin);

        // Verify contractURI works
        string memory uri = token.contractURI();
        assertTrue(bytes(uri).length > 0);

        // Verify tokenURI matches
        assertEq(token.tokenURI(), uri);
    }

    function test_fork_deployAndSetRenderer() public onlyFork {
        IArtCoinsFactory.TokenConfig memory config = IArtCoinsFactory.TokenConfig({
            tokenAdmin: tokenAdmin,
            name: "Rendered Token",
            symbol: "RND",
            salt: bytes32(uint256(block.timestamp + 1)),
            image: "https://example.com/rendered.png",
            metadata: "Rendered token desc",
            context: "renderer test",
            totalSupply: 0,
            renderer: address(0)
        });

        address tokenAddr = ArtCoinsDeployer.deployToken(config, TOKEN_SUPPLY);

        ArtCoinsToken token = ArtCoinsToken(tokenAddr);

        // Set renderer
        vm.prank(tokenAdmin);
        token.setMetadataRenderer(address(renderer));

        assertEq(token.metadataRenderer(), address(renderer));
        string memory uri = token.contractURI();
        assertTrue(bytes(uri).length > 0);
    }

    // ─── Fee locker on fork ─────────────────────────────────────────────

    function test_fork_feeLockerDeployment() public onlyFork {
        // Fee locker should be deployed and functional
        assertTrue(address(feeLocker).code.length > 0);
    }

    // ─── Multiple token deployments ─────────────────────────────────────

    function test_fork_multipleTokenDeploys() public onlyFork {
        address[] memory tokens = new address[](3);

        for (uint256 i = 0; i < 3; i++) {
            IArtCoinsFactory.TokenConfig memory config = IArtCoinsFactory.TokenConfig({
                tokenAdmin: tokenAdmin,
                name: string.concat("Token", vm.toString(i)),
                symbol: string.concat("T", vm.toString(i)),
                salt: bytes32(uint256(block.timestamp + 100 + i)),
                image: "https://example.com/multi.png",
                metadata: "Multi deploy test",
                context: "batch",
                totalSupply: 0,
                renderer: address(0)
            });

            tokens[i] = ArtCoinsDeployer.deployToken(config, TOKEN_SUPPLY);
        }

        // All tokens should be unique
        assertTrue(tokens[0] != tokens[1]);
        assertTrue(tokens[1] != tokens[2]);
        assertTrue(tokens[0] != tokens[2]);

        // All should be functional
        for (uint256 i = 0; i < 3; i++) {
            ArtCoinsToken t = ArtCoinsToken(tokens[i]);
            assertEq(t.totalSupply(), TOKEN_SUPPLY);
            assertEq(t.admin(), tokenAdmin);
        }
    }

    // ─── Full flow: deploy, transfer, burn, upgrade ─────────────────────

    function test_fork_fullTokenLifecycle() public onlyFork {
        // Deploy
        IArtCoinsFactory.TokenConfig memory config = IArtCoinsFactory.TokenConfig({
            tokenAdmin: tokenAdmin,
            name: "Lifecycle Token",
            symbol: "LIFE",
            salt: bytes32(uint256(block.timestamp + 999)),
            image: "https://example.com/life.png",
            metadata: "Lifecycle test",
            context: "full flow",
            totalSupply: 0,
            renderer: address(0)
        });

        address tokenAddr = ArtCoinsDeployer.deployToken(config, TOKEN_SUPPLY);
        ArtCoinsToken token = ArtCoinsToken(tokenAddr);

        // Transfer some tokens
        address user = address(0xBEEF);
        token.transfer(user, 1_000_000e18);
        assertEq(token.balanceOf(user), 1_000_000e18);

        // User burns tokens
        vm.prank(user);
        token.burn(500_000e18);
        assertEq(token.balanceOf(user), 500_000e18);
        assertEq(token.totalSupply(), TOKEN_SUPPLY - 500_000e18);

        // Admin updates metadata
        vm.startPrank(tokenAdmin);
        token.updateMetadata("Updated lifecycle description");
        token.updateImage("https://example.com/life-v2.png");

        // Admin sets renderer
        token.setMetadataRenderer(address(renderer));
        vm.stopPrank();

        // Verify metadata
        assertEq(token.metadata(), "Updated lifecycle description");
        assertEq(token.imageUrl(), "https://example.com/life-v2.png");
        assertEq(token.metadataRenderer(), address(renderer));
        assertTrue(bytes(token.contractURI()).length > 0);
        assertEq(token.tokenURI(), token.contractURI());

        // Admin verifies token
        vm.prank(tokenAdmin);
        token.verify();
        assertTrue(token.isVerified());
    }
}
