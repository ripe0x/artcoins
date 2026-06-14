// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test, console2} from "forge-std/Test.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {ArtCoinsFactory} from "../src/ArtCoinsFactory.sol";
import {ArtCoinsFeeEscrow} from "../src/ArtCoinsFeeEscrow.sol";
import {ArtCoinsUniv4EthDevBuy} from "../src/extensions/ArtCoinsUniv4EthDevBuy.sol";
import {ArtCoinsHookStaticFee} from "../src/hooks/ArtCoinsHookStaticFee.sol";
import {ArtCoinsPoolExtensionAllowlist} from "../src/hooks/ArtCoinsPoolExtensionAllowlist.sol";
import {ArtCoinsLpLocker} from "../src/lp-lockers/ArtCoinsLpLocker.sol";

import {IArtCoinsUniv4EthDevBuy} from "../src/extensions/interfaces/IArtCoinsUniv4EthDevBuy.sol";
import {IArtCoinsHookStaticFee} from "../src/hooks/interfaces/IArtCoinsHookStaticFee.sol";
import {IArtCoinsFactory} from "../src/interfaces/IArtCoinsFactory.sol";
import {IArtCoinsHook} from "../src/interfaces/IArtCoinsHook.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Fork test for the V3 dev-buy extension's native-ETH support
///         (audit M-01 fix). Verifies that a native-ETH artcoin can launch
///         with an at-deploy dev buy without reverting.
contract ArtCoinsUniv4EthDevBuyForkTest is Test {
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;

    ArtCoinsFactory factory;
    ArtCoinsFeeEscrow escrow;
    ArtCoinsHookStaticFee hook;
    ArtCoinsLpLocker locker;
    ArtCoinsPoolExtensionAllowlist extAllowlist;
    ArtCoinsUniv4EthDevBuy devBuy;

    address owner = makeAddr("owner");
    address tokenAdmin = makeAddr("tokenAdmin");
    address teamRecipient = makeAddr("teamRecipient");
    address creatorSlot = makeAddr("creatorSlot");
    address devBuyRecipient = makeAddr("devBuyRecipient");

    bool _onFork;

    function setUp() public {
        if (POOL_MANAGER.code.length == 0) {
            console2.log("SKIPPING: not on mainnet fork");
            return;
        }
        _onFork = true;

        vm.startPrank(owner);
        factory = new ArtCoinsFactory(owner);
        escrow = new ArtCoinsFeeEscrow(owner);
        extAllowlist = new ArtCoinsPoolExtensionAllowlist(owner);

        factory.setDeprecated(false);
        factory.setTeamFeeRecipient(teamRecipient);
        factory.setDeployFee(0);

        locker = new ArtCoinsLpLocker(
            owner, address(factory), address(escrow), POSITION_MANAGER, PERMIT2
        );

        escrow.addDepositor(address(locker));
        vm.stopPrank();

        // Mine + deploy hook.
        uint160 hookFlags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory hookCtorArgs = abi.encode(
            POOL_MANAGER, address(factory), address(extAllowlist), WETH, address(escrow)
        );
        (address minedHook, bytes32 hookSalt) = HookMiner.find(
            address(this), hookFlags, type(ArtCoinsHookStaticFee).creationCode, hookCtorArgs
        );
        hook = new ArtCoinsHookStaticFee{salt: hookSalt}(
            POOL_MANAGER, address(factory), address(extAllowlist), WETH, address(escrow)
        );
        require(address(hook) == minedHook, "hook mine mismatch");

        // V3 dev-buy extension.
        devBuy = new ArtCoinsUniv4EthDevBuy(address(factory), WETH, UNIVERSAL_ROUTER, PERMIT2);

        vm.startPrank(owner);
        factory.setHook(address(hook), true);
        factory.setLocker(address(locker), address(hook), true);
        factory.setExtension(address(devBuy), true);
        escrow.addDepositor(address(hook));
        vm.stopPrank();
    }

    modifier onlyFork() {
        if (!_onFork) return;
        _;
    }

    receive() external payable {}

    function _buildConfig(uint16 projectBps, bytes32 salt, uint256 devBuyEth)
        internal
        view
        returns (IArtCoinsFactory.DeploymentConfig memory cfg)
    {
        cfg.tokenConfig = IArtCoinsFactory.TokenConfig({
            tokenAdmin: tokenAdmin,
            name: "DevBuyV3",
            symbol: "DBV3",
            salt: salt,
            image: "",
            metadata: "",
            context: "",
            totalSupply: 0,
            renderer: address(0)
        });

        cfg.poolConfig = IArtCoinsFactory.PoolConfig({
            hook: address(hook),
            pairedToken: address(0), // native ETH — the V1 dev-buy can't handle this
            tickIfToken0IsArtCoins: -100_000,
            tickSpacing: 200,
            poolData: abi.encode(
                IArtCoinsHook.PoolInitializationData({
                    extension: address(0),
                    extensionData: "",
                    feeData: abi.encode(
                        IArtCoinsHookStaticFee.PoolStaticConfigVars({
                            artCoinFee: 10_000, pairedFee: 10_000
                        })
                    )
                })
            )
        });

        address[] memory admins = new address[](1);
        admins[0] = tokenAdmin;
        address[] memory recipients = new address[](1);
        recipients[0] = creatorSlot;
        uint16[] memory rewardBps = new uint16[](1);
        rewardBps[0] = projectBps;

        int24[] memory tickLower = new int24[](1);
        int24[] memory tickUpper = new int24[](1);
        uint16[] memory positionBps = new uint16[](1);
        tickLower[0] = 0;
        tickUpper[0] = 110_400;
        positionBps[0] = 10_000;

        cfg.lockerConfig = IArtCoinsFactory.LockerConfig({
            locker: address(locker),
            rewardAdmins: admins,
            rewardRecipients: recipients,
            rewardBps: rewardBps,
            tickLower: tickLower,
            tickUpper: tickUpper,
            positionBps: positionBps,
            lockerData: ""
        });

        cfg.mevModuleConfig =
            IArtCoinsFactory.MevModuleConfig({mevModule: address(0), mevModuleData: ""});
        cfg.sniperFeeConfig =
            IArtCoinsFactory.SniperFeeConfig({recipient: address(0), lockRecipient: false});

        // Configure dev-buy extension.
        // pairedTokenPoolKey is unused for native-ETH artcoins (the V3 path
        // skips the intermediate hop), but we still need to satisfy the
        // struct's ABI shape.
        PoolKey memory dummyPairedKey;
        IArtCoinsUniv4EthDevBuy.Univ4EthDevBuyExtensionData memory devBuyData =
            IArtCoinsUniv4EthDevBuy.Univ4EthDevBuyExtensionData({
                pairedTokenPoolKey: dummyPairedKey,
                pairedTokenAmountOutMinimum: 0,
                // V3 addition: real slippage floor on the final leg (V1 hardcoded 1).
                // Set to 1 for the test since we're just verifying the call doesn't revert.
                tokenAmountOutMinimum: 1,
                recipient: devBuyRecipient
            });

        cfg.extensionConfigs = new IArtCoinsFactory.ExtensionConfig[](1);
        cfg.extensionConfigs[0] = IArtCoinsFactory.ExtensionConfig({
            extension: address(devBuy),
            msgValue: devBuyEth,
            extensionBps: 0,
            extensionData: abi.encode(devBuyData)
        });
    }

    /// @notice M-01 fix: native-ETH artcoin can launch with an at-deploy dev
    ///         buy. V1 dev-buy would revert atomically because of the
    ///         WETH/intermediate-hop branch trying to handle `address(0)`.
    function test_fork_M01_nativeEthArtcoin_withDevBuy_succeeds() public onlyFork {
        uint256 devBuyEth = 0.5 ether;
        IArtCoinsFactory.DeploymentConfig memory cfg =
            _buildConfig(8000, keccak256("m01_native_devbuy"), devBuyEth);

        vm.deal(owner, devBuyEth);
        vm.prank(owner);
        address tokenAddr = factory.deployToken{value: devBuyEth}(cfg);

        // Dev-buy recipient should have received some artcoin tokens.
        uint256 recipientBalance = IERC20(tokenAddr).balanceOf(devBuyRecipient);
        assertGt(recipientBalance, 0, "dev-buy recipient should hold artcoins");
    }

    /// @notice Sanity: the V3 dev-buy interface includes tokenAmountOutMinimum.
    function test_extensionData_includesTokenAmountOutMinimum() public pure {
        IArtCoinsUniv4EthDevBuy.Univ4EthDevBuyExtensionData memory d;
        d.tokenAmountOutMinimum = 12_345;
        assertEq(d.tokenAmountOutMinimum, 12_345);
    }
}
