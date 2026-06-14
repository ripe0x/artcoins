// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {LaunchLayer} from "../script/LaunchLayer.s.sol";
import {IArtCoinsFactory} from "../src/interfaces/IArtCoinsFactory.sol";
import {IArtCoinsHook} from "../src/interfaces/IArtCoinsHook.sol";
import {BurnRouter} from "../src/protocol-fee/BurnRouter.sol";
import {ArtCoinsDeployer} from "../src/utils/ArtCoinsDeployer.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract LaunchLayerHarness is LaunchLayer {
    function exposedBuildConfig(
        address deployer,
        address artistTreasury,
        address artistRecipient,
        address hook,
        address locker,
        address mevSniperStepped,
        address airdrop,
        address burnExtension,
        address llCounter,
        address llRenderer,
        address weth,
        address burnRouter,
        int24 startingTick
    ) external pure returns (IArtCoinsFactory.DeploymentConfig memory) {
        return _buildConfig(
            deployer,
            artistTreasury,
            artistRecipient,
            hook,
            locker,
            mevSniperStepped,
            airdrop,
            burnExtension,
            llCounter,
            llRenderer,
            weth,
            burnRouter,
            startingTick,
            ""
        );
    }

    function exposedVerifyLpShape(int24 startingTick) external pure {
        _verifyLpShape(startingTick);
    }

    function exposedPredictTokenAddress(
        address factoryAddr,
        IArtCoinsFactory.TokenConfig memory tokenConfig,
        uint256 totalSupply
    ) external pure returns (address) {
        return _predictTokenAddress(factoryAddr, tokenConfig, totalSupply);
    }

    function exposedCanonicalPoolKey(address layer, address weth, address hook)
        external
        pure
        returns (PoolKey memory)
    {
        return _canonicalPoolKey(layer, weth, hook);
    }

    function exposedPreflightBurnRouter(
        address burnRouter,
        address layer,
        address weth,
        PoolKey memory canonicalKey,
        address deployer
    ) external view returns (bool) {
        return _preflightBurnRouter(burnRouter, layer, weth, canonicalKey, deployer);
    }
}

contract TokenDeployHarness {
    function deploy(IArtCoinsFactory.TokenConfig memory tokenConfig, uint256 supply)
        external
        returns (address)
    {
        return ArtCoinsDeployer.deployToken(tokenConfig, supply);
    }
}

contract LaunchLayerMockErc20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}
}

contract LaunchLayerScriptChecksTest is Test {
    LaunchLayerHarness internal harness;

    address internal deployer = address(0xA11CE);
    address internal artistTreasury = address(0xA2);
    address internal artistRecipient = address(0xA3);
    address internal hook = address(0xA4);
    address internal locker = address(0xA5);
    address internal mev = address(0xA6);
    address internal airdrop = address(0xA7);
    address internal burnExtension = address(0xA8);
    address internal llCounter = address(0xA9);
    address internal llRenderer = address(0xAA);
    address internal burnRouter = address(0xB0);
    address internal universalRouter = address(0xC0);
    address internal permit2 = address(0xD0);

    function setUp() public {
        harness = new LaunchLayerHarness();
    }

    function test_buildConfigSetsLockedBurnRouterSniperConfig() public view {
        IArtCoinsFactory.DeploymentConfig memory config = harness.exposedBuildConfig(
            deployer,
            artistTreasury,
            artistRecipient,
            hook,
            locker,
            mev,
            airdrop,
            burnExtension,
            llCounter,
            llRenderer,
            address(0xE0),
            burnRouter,
            -190_400
        );

        assertEq(config.sniperFeeConfig.recipient, burnRouter);
        assertTrue(config.sniperFeeConfig.lockRecipient);
        assertEq(config.tokenConfig.renderer, llRenderer);
        IArtCoinsHook.PoolInitializationData memory poolData =
            abi.decode(config.poolConfig.poolData, (IArtCoinsHook.PoolInitializationData));
        assertEq(poolData.extension, llCounter);
    }

    function test_verifyLpShapeRejectsWrongAlignedStartingTick() public {
        vm.expectRevert(bytes("LP first tickLower mismatch"));
        harness.exposedVerifyLpShape(-190_200);
    }

    function test_predictTokenAddressMatchesActualDeploy() public {
        TokenDeployHarness deployHarness = new TokenDeployHarness();
        IArtCoinsFactory.TokenConfig memory tokenConfig = IArtCoinsFactory.TokenConfig({
            tokenAdmin: deployer,
            name: "Liquidity Layer",
            symbol: "LAYER",
            salt: bytes32(0),
            image: "",
            metadata: "Liquidity Layer mainnet -- first artcoin, continuation of Base LL",
            context: "layer-mainnet",
            totalSupply: 1_000_000_000e18,
            renderer: address(0)
        });

        address predicted = harness.exposedPredictTokenAddress(
            address(deployHarness), tokenConfig, tokenConfig.totalSupply
        );
        address actual = deployHarness.deploy(tokenConfig, tokenConfig.totalSupply);

        assertEq(actual, predicted);
    }

    function test_preflightAllowsSignerOwnedUninitializedBurnRouter() public {
        LaunchLayerMockErc20 layer = new LaunchLayerMockErc20("Layer", "LAYER");
        LaunchLayerMockErc20 weth = new LaunchLayerMockErc20("WETH", "WETH");
        BurnRouter router = new BurnRouter(deployer);
        PoolKey memory key = harness.exposedCanonicalPoolKey(address(layer), address(weth), hook);

        bool shouldInitialize = harness.exposedPreflightBurnRouter(
            address(router), address(layer), address(weth), key, deployer
        );

        assertTrue(shouldInitialize);
    }

    function test_preflightRejectsUninitializedBurnRouterOwnedByOther() public {
        LaunchLayerMockErc20 layer = new LaunchLayerMockErc20("Layer", "LAYER");
        LaunchLayerMockErc20 weth = new LaunchLayerMockErc20("WETH", "WETH");
        BurnRouter router = new BurnRouter(address(0xBAD));
        PoolKey memory key = harness.exposedCanonicalPoolKey(address(layer), address(weth), hook);

        vm.expectRevert(bytes("BurnRouter must be initialized or signer must own it"));
        harness.exposedPreflightBurnRouter(
            address(router), address(layer), address(weth), key, deployer
        );
    }

    function test_preflightAcceptsCorrectlyInitializedBurnRouter() public {
        LaunchLayerMockErc20 layer = new LaunchLayerMockErc20("Layer", "LAYER");
        LaunchLayerMockErc20 weth = new LaunchLayerMockErc20("WETH", "WETH");
        BurnRouter router = new BurnRouter(deployer);
        PoolKey memory key = harness.exposedCanonicalPoolKey(address(layer), address(weth), hook);

        vm.prank(deployer);
        router.initialize(
            address(layer), address(weth), key, address(0xC0FFEe0000000000000000000000000000000001)
        );

        bool shouldInitialize = harness.exposedPreflightBurnRouter(
            address(router), address(layer), address(weth), key, deployer
        );

        assertFalse(shouldInitialize);
    }

    function test_preflightRejectsWrongInitializedBurnRouter() public {
        LaunchLayerMockErc20 layer = new LaunchLayerMockErc20("Layer", "LAYER");
        LaunchLayerMockErc20 wrongLayer = new LaunchLayerMockErc20("Wrong", "WRONG");
        LaunchLayerMockErc20 weth = new LaunchLayerMockErc20("WETH", "WETH");
        BurnRouter router = new BurnRouter(deployer);
        PoolKey memory wrongKey =
            harness.exposedCanonicalPoolKey(address(wrongLayer), address(weth), hook);
        PoolKey memory expectedKey =
            harness.exposedCanonicalPoolKey(address(layer), address(weth), hook);

        vm.prank(deployer);
        router.initialize(
            address(wrongLayer),
            address(weth),
            wrongKey,
            address(0xC0FFEe0000000000000000000000000000000001)
        );

        vm.expectRevert(bytes("BurnRouter LAYER mismatch"));
        harness.exposedPreflightBurnRouter(
            address(router), address(layer), address(weth), expectedKey, deployer
        );
    }
}
