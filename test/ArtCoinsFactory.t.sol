// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test, console2} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {ArtCoinsFactory} from "../src/ArtCoinsFactory.sol";
import {ArtCoinsFeeEscrow} from "../src/ArtCoinsFeeEscrow.sol";
import {ArtCoinsHookStaticFee} from "../src/hooks/ArtCoinsHookStaticFee.sol";
import {ArtCoinsPoolExtensionAllowlist} from "../src/hooks/ArtCoinsPoolExtensionAllowlist.sol";
import {IArtCoinsHookStaticFee} from "../src/hooks/interfaces/IArtCoinsHookStaticFee.sol";
import {IArtCoinsFactory} from "../src/interfaces/IArtCoinsFactory.sol";
import {IArtCoinsHook} from "../src/interfaces/IArtCoinsHook.sol";
import {ArtCoinsLpLocker} from "../src/lp-lockers/ArtCoinsLpLocker.sol";

/// @notice Tests for ArtCoinsFactory — focused on the new per-deploy
///         protocol-bps override. The rest of the factory behavior is
///         byte-identical to V1 and covered by existing factory tests.
contract ArtCoinsFactoryTest is Test {
    ArtCoinsFactory public factory;
    address public owner = address(0xCAFE);

    function setUp() public {
        vm.prank(owner);
        factory = new ArtCoinsFactory(owner);
    }

    function test_constants() public view {
        assertEq(factory.MAX_PROTOCOL_FEE_BPS(), 3000);
        assertEq(factory.defaultProtocolFeeBps(), 2000);
    }

    function test_version() public view {
        assertEq(factory.version(), "1");
    }

    function test_deployTokenWithProtocolBps_revertsIfTooHigh() public {
        IArtCoinsFactory.DeploymentConfig memory config;
        vm.expectRevert(IArtCoinsFactory.ProtocolFeeBpsTooHigh.selector);
        factory.deployTokenWithProtocolBps(config, 3001);
    }

    function test_deployTokenWithProtocolBps_atCap_doesntRevertOnBps() public {
        // 3000 bps is the cap — should NOT revert on the bps check. It WILL
        // revert downstream (empty config triggers `ZeroAddress` in the token
        // deployer), but specifically NOT `ProtocolFeeBpsTooHigh`.
        IArtCoinsFactory.DeploymentConfig memory config;
        vm.startPrank(owner);
        factory.setDeprecated(false);
        // Expect ANY revert other than ProtocolFeeBpsTooHigh — we just want
        // to confirm 3000 itself isn't rejected.
        (bool ok, bytes memory ret) = address(factory)
            .call(
                abi.encodeWithSelector(
                    factory.deployTokenWithProtocolBps.selector, config, uint16(3000)
                )
            );
        vm.stopPrank();
        assertFalse(ok, "should revert downstream");
        // Confirm it didn't revert with ProtocolFeeBpsTooHigh.
        bytes4 selector;
        assembly { selector := mload(add(ret, 32)) }
        assertTrue(
            selector != IArtCoinsFactory.ProtocolFeeBpsTooHigh.selector,
            "should not be bps-too-high"
        );
    }

    function test_perDeployOverride_doesntMutateGlobalDefault() public {
        // Save the global default, attempt an override (will revert), confirm
        // the global default is unchanged after.
        uint16 before_ = factory.defaultProtocolFeeBps();

        IArtCoinsFactory.DeploymentConfig memory config;
        try factory.deployTokenWithProtocolBps(config, 1000) {} catch {}

        assertEq(factory.defaultProtocolFeeBps(), before_, "global default mutated");
    }

    // M-02 audit fix: factory must accept native ETH so the hook's reserved
    // protocol-fee path doesn't brick native-ETH pools if ever enabled.
    function test_receive_acceptsNativeEth() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(factory).call{value: 0.5 ether}("");
        assertTrue(ok, "factory must accept ETH (M-02 fix)");
        assertEq(address(factory).balance, 0.5 ether);
    }

    function test_recoverETH_canSweepReceivedEth() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(factory).call{value: 0.7 ether}("");
        assertTrue(ok);

        address payable sink = payable(makeAddr("sink"));
        vm.prank(owner);
        factory.recoverETH(sink);
        assertEq(sink.balance, 0.7 ether);
        assertEq(address(factory).balance, 0);
    }
}

// ═══════════════════════════════════════════════════════════════════════
//   Fork integration: per-deploy override produces a pool whose protocol
//   slot carries the override bps (not the global default).
// ═══════════════════════════════════════════════════════════════════════

contract ArtCoinsFactoryForkTest is Test {
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    ArtCoinsFactory factory;
    ArtCoinsFeeEscrow escrow;
    ArtCoinsHookStaticFee hook;
    ArtCoinsLpLocker locker;
    ArtCoinsPoolExtensionAllowlist extAllowlist;

    address owner = makeAddr("owner");
    address tokenAdmin = makeAddr("tokenAdmin");
    address teamRecipient = makeAddr("teamRecipient");
    address creatorSlot = makeAddr("creatorSlot");

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
        require(address(hook) == minedHook, "hook mismatch");
        // M-03 fix: allowlist hook as escrow depositor for sniper-extra routing.
        vm.prank(owner);
        escrow.addDepositor(address(hook));

        vm.startPrank(owner);
        factory.setHook(address(hook), true);
        factory.setLocker(address(locker), address(hook), true);
        vm.stopPrank();
    }

    modifier onlyFork() {
        if (!_onFork) return;
        _;
    }

    receive() external payable {}

    function _buildConfig(uint16 projectBps, bytes32 salt)
        internal
        view
        returns (IArtCoinsFactory.DeploymentConfig memory cfg)
    {
        cfg.tokenConfig = IArtCoinsFactory.TokenConfig({
            tokenAdmin: tokenAdmin,
            name: "FactoryV3Test",
            symbol: "F3T",
            salt: salt,
            image: "",
            metadata: "",
            context: "",
            totalSupply: 0,
            renderer: address(0)
        });

        cfg.poolConfig = IArtCoinsFactory.PoolConfig({
            hook: address(hook),
            pairedToken: address(0),
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
        cfg.extensionConfigs = new IArtCoinsFactory.ExtensionConfig[](0);
    }

    /// @notice deployTokenWithProtocolBps(config, 1000) produces a pool whose
    ///         protocol slot is 1000 bps (10%), with project-side at 9000.
    function test_fork_override_10pct_routesCorrectly() public onlyFork {
        // Project-side bps = 9000 (so 9000 + 1000 = 10000).
        IArtCoinsFactory.DeploymentConfig memory cfg = _buildConfig(9000, keccak256("ten_pct"));

        vm.prank(owner);
        address tokenAddr = factory.deployTokenWithProtocolBps(cfg, 1000);

        // Inspect locker's recorded rewards: first slot creator (9000), second slot teamRecipient (1000).
        (uint16[] memory bps, address[] memory recipients) = _readLockerSlots(tokenAddr);
        assertEq(bps.length, 2, "should have 2 slots: creator + protocol");
        assertEq(bps[0], 9000, "creator gets 9000 bps");
        assertEq(recipients[0], creatorSlot);
        assertEq(bps[1], 1000, "protocol gets 1000 bps");
        assertEq(recipients[1], teamRecipient);
    }

    /// @notice Standard deployToken uses the global default (2000).
    function test_fork_deployToken_usesGlobalDefault() public onlyFork {
        // Default is 2000, so project-side must be 8000.
        IArtCoinsFactory.DeploymentConfig memory cfg = _buildConfig(8000, keccak256("default"));

        vm.prank(owner);
        address tokenAddr = factory.deployToken(cfg);

        (uint16[] memory bps,) = _readLockerSlots(tokenAddr);
        assertEq(bps[0], 8000, "creator gets 8000 bps");
        assertEq(bps[1], 2000, "protocol gets default 2000 bps");
    }

    /// @notice deployTokenWithProtocolBps(config, 0) disables the protocol slot.
    ///         Deployer's bps must then sum to 10_000.
    function test_fork_override_zero_disablesProtocolSlot() public onlyFork {
        // Project-side = 10000 since no protocol slot.
        IArtCoinsFactory.DeploymentConfig memory cfg = _buildConfig(10_000, keccak256("zero"));

        vm.prank(owner);
        address tokenAddr = factory.deployTokenWithProtocolBps(cfg, 0);

        (uint16[] memory bps, address[] memory recipients) = _readLockerSlots(tokenAddr);
        assertEq(bps.length, 1, "only creator slot when protocol disabled");
        assertEq(bps[0], 10_000);
        assertEq(recipients[0], creatorSlot);
    }

    /// @notice After a per-deploy override, the global default is unchanged.
    function test_fork_perDeployOverride_doesntPersist() public onlyFork {
        uint16 before_ = factory.defaultProtocolFeeBps();

        // Deploy two tokens: one with override (1000), one with default (2000).
        IArtCoinsFactory.DeploymentConfig memory cfg1 = _buildConfig(9000, keccak256("a"));
        vm.prank(owner);
        factory.deployTokenWithProtocolBps(cfg1, 1000);

        // Global default unchanged.
        assertEq(factory.defaultProtocolFeeBps(), before_);

        // Now use deployToken — should use global default (2000).
        IArtCoinsFactory.DeploymentConfig memory cfg2 = _buildConfig(8000, keccak256("b"));
        vm.prank(owner);
        address tokenAddr2 = factory.deployToken(cfg2);

        (uint16[] memory bps,) = _readLockerSlots(tokenAddr2);
        assertEq(bps[1], 2000, "second deploy reverts to global default");
    }

    /// @dev Helper to read the locker's recorded rewardBps + recipients for a token.
    function _readLockerSlots(address token)
        internal
        view
        returns (uint16[] memory bps, address[] memory recipients)
    {
        bps = locker.tokenRewards(token).rewardBps;
        recipients = locker.tokenRewards(token).rewardRecipients;
    }
}
