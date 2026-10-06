// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ForkBase} from "./ForkBase.sol";

import {LaunchDefaults} from "../../../script/LaunchDefaults.sol";
import {ArtCoinsFactory} from "../../../src/ArtCoinsFactory.sol";
import {ArtCoinsFeeEscrow} from "../../../src/ArtCoinsFeeEscrow.sol";
import {ArtCoinsHookSkimFee} from "../../../src/hooks/ArtCoinsHookSkimFee.sol";
import {ArtCoinsPoolExtensionAllowlist} from "../../../src/hooks/ArtCoinsPoolExtensionAllowlist.sol";
import {IArtCoinsHookSkimFee} from "../../../src/hooks/interfaces/IArtCoinsHookSkimFee.sol";
import {IArtCoinsFactory} from "../../../src/interfaces/IArtCoinsFactory.sol";
import {IArtCoinsHook} from "../../../src/interfaces/IArtCoinsHook.sol";
import {IArtCoinsLpLocker} from "../../../src/interfaces/IArtCoinsLpLocker.sol";
import {TaxConfig, TaxVenue} from "../../../src/interfaces/IArtCoinsTaxable.sol";
import {ArtCoinsLpLocker} from "../../../src/lp-lockers/ArtCoinsLpLocker.sol";
import {ArtCoinsMevLinearSkim} from "../../../src/mev-modules/ArtCoinsMevLinearSkim.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

/// @title  ForkStack
/// @notice Fresh-stack deployer and launcher on top of live mainnet v4, plus a
///         typed view of the live deployed stack.
/// @dev    `deployFreshStack()` mirrors `script/DeployV1Stack.s.sol`
///         `deployStack()` (the script whose wiring matches the live factory
///         0x4959…: version "1", teamFeeRecipient == owner, hook + locker + mev
///         enabled, escrow depositors = locker + hook, locker keeperRewardBps 0).
///         Divergences, all deliberate and listed in docs/v2/review/harness.md:
///           1. the hook salt is mined against `address(this)` (forge test does
///              not route `new{salt}` through CREATE2_DEPLOYER), like
///              test/DeployV1StackForkTest.t.sol;
///           2. after the script wiring, deployFee is reset to the live value
///              (0.069 eth; the script sets 0, the live factory reads 0.069);
///           3. the factory is un-deprecated so non-owner launches work.
abstract contract ForkStack is ForkBase {
    using PoolIdLibrary for PoolKey;

    /// @dev Live factory deployFee read at FORK_BLOCK.
    uint256 internal constant LIVE_DEPLOY_FEE = 0.069 ether;

    /// @dev Flags from test/ArtCoinsHookSkimFeeForkTest.t.sol (and DeployV1Stack).
    uint160 internal constant SKIM_HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    /// @dev LAYER starting tick (script/LaunchLayer.s.sol EXPECTED_LP_LOWEST_TICK).
    int24 internal constant DEFAULT_STARTING_TICK = -190_400;

    struct FreshStack {
        ArtCoinsFactory factory;
        ArtCoinsFeeEscrow escrow;
        ArtCoinsPoolExtensionAllowlist poolExtAllowlist;
        ArtCoinsHookSkimFee hook;
        ArtCoinsLpLocker locker;
        ArtCoinsMevLinearSkim mev;
        address owner;
    }

    struct LiveStack {
        address factory;
        address hook;
        address locker;
        address escrow;
        address mev;
        address poolExtAllowlist;
        address owner;
        address olderFactory;
        address legacyFactory;
        address coin111;
        PoolKey coin111Key;
        PoolId coin111Id;
    }

    /// @notice Launch inputs. `defaultLaunchParams()` fills every field.
    struct LaunchParams {
        string name;
        string symbol;
        address tokenAdmin;
        bytes32 salt;
        uint256 totalSupply; // 0 = factory default (1B)
        int24 tickIfToken0IsArtCoins; // multiple of 200
        // skim hook fee data
        uint24 lpFee;
        uint24 baselineSkimBps;
        uint16 bountyBps;
        uint24 maxReferralBpsOfVolume;
        address payable bountyRecipient;
        address payable protocolRecipient;
        address payable referralPayout;
        // mev module init (startingBps, endingBps, duration); "" = module defaults
        bytes mevModuleData;
        // locker rewards (project side; the factory appends the protocol slot)
        address[] rewardAdmins;
        address[] rewardRecipients;
        uint16[] rewardBps;
        uint16 protocolBps; // must equal 10_000 - sum(rewardBps)
        // optional venue-scoped buy tax (0 = dormant, 111 used 1500)
        uint16 taxBps;
        address launcher; // msg.sender of the deploy call
    }

    struct Launched {
        address token;
        PoolKey key;
        PoolId id;
        uint256 positionId;
        uint256 numPositions;
        int24[] tickLower;
        int24[] tickUpper;
        uint16[] positionBps;
    }

    FreshStack internal stack;

    // ─── fresh stack ─────────────────────────────────────────────────────

    /// @notice Deploys the repo's current src stack on the fork, owned by
    ///         `makeAddr("artcoins-test-owner")`, un-deprecated.
    function deployFreshStack() internal returns (FreshStack memory s) {
        s.owner = makeAddr("artcoins-test-owner");

        // DeployV1Stack.deployStack order: factory, escrow, allowlist, hook, locker, mev.
        s.factory = new ArtCoinsFactory(s.owner);
        s.escrow = new ArtCoinsFeeEscrow(s.owner);
        s.poolExtAllowlist = new ArtCoinsPoolExtensionAllowlist(s.owner);
        {
            bytes memory ctorArgs = abi.encode(
                POOL_MANAGER, address(s.factory), address(s.poolExtAllowlist), WETH, address(s.escrow)
            );
            (address mined, bytes32 salt) = HookMiner.find(
                address(this), SKIM_HOOK_FLAGS, type(ArtCoinsHookSkimFee).creationCode, ctorArgs
            );
            s.hook = new ArtCoinsHookSkimFee{salt: salt}(
                POOL_MANAGER, address(s.factory), address(s.poolExtAllowlist), WETH, address(s.escrow)
            );
            require(address(s.hook) == mined, "ForkStack: hook address mismatch");
        }
        s.locker =
            new ArtCoinsLpLocker(s.owner, address(s.factory), address(s.escrow), POSITION_MANAGER, PERMIT2);
        s.mev = new ArtCoinsMevLinearSkim();

        // DeployV1Stack.deployStack wiring, same order.
        vm.startPrank(s.owner);
        s.factory.setTeamFeeRecipient(s.owner);
        s.factory.setDeployFee(0);
        s.factory.setHook(address(s.hook), true);
        s.factory.setLocker(address(s.locker), address(s.hook), true);
        s.factory.setMevModule(address(s.mev), true);
        s.escrow.addDepositor(address(s.locker));
        s.escrow.addDepositor(address(s.hook));
        s.locker.setKeeperRewardBps(0);
        // harness-only: live parity + open for public launches.
        s.factory.setDeployFee(LIVE_DEPLOY_FEE);
        s.factory.setDeprecated(false);
        vm.stopPrank();

        vm.label(address(s.factory), "freshFactory");
        vm.label(address(s.escrow), "freshEscrow");
        vm.label(address(s.hook), "freshHook");
        vm.label(address(s.locker), "freshLocker");
        vm.label(address(s.mev), "freshMevSkim");
        stack = s;
    }

    // ─── launch ──────────────────────────────────────────────────────────

    /// @notice Defaults: LaunchDefaults tick spacing 200 + LAYER 12 position
    ///         thin-floor taper from DEFAULT_STARTING_TICK (LaunchLayer.s.sol);
    ///         LaunchLayer reward split 3800 artist / 4200 project + factory
    ///         default 2000 protocol; skim fee + mev schedule copied from the
    ///         live coin 111 pool (lpFee 5000, baseline 6000, bounty 8333,
    ///         maxRef 250; mev 90000 -> 6000 over 30 min). Tax off.
    function defaultLaunchParams() internal returns (LaunchParams memory p) {
        p.name = "Harness Coin";
        p.symbol = "HARN";
        p.tokenAdmin = makeAddr("tokenAdmin");
        p.salt = bytes32(0);
        p.totalSupply = 0;
        p.tickIfToken0IsArtCoins = DEFAULT_STARTING_TICK;
        p.lpFee = 5000;
        p.baselineSkimBps = 6000;
        p.bountyBps = 8333;
        p.maxReferralBpsOfVolume = 250;
        p.bountyRecipient = payable(makeAddr("bountyRecipient"));
        p.protocolRecipient = payable(makeAddr("protocolRecipient"));
        p.referralPayout = payable(makeAddr("referralPayout"));
        p.mevModuleData = abi.encode(uint24(90_000), uint24(6000), uint32(30 minutes));
        p.rewardAdmins = new address[](2);
        p.rewardRecipients = new address[](2);
        p.rewardBps = new uint16[](2);
        p.rewardAdmins[0] = makeAddr("artistAdmin");
        p.rewardAdmins[1] = makeAddr("projectAdmin");
        p.rewardRecipients[0] = makeAddr("artistRecipient");
        p.rewardRecipients[1] = makeAddr("projectRecipient");
        p.rewardBps[0] = 3800;
        p.rewardBps[1] = 4200;
        p.protocolBps = 2000;
        p.taxBps = 0;
        p.launcher = makeAddr("launcher");
    }

    /// @notice Launch a coin on the fresh stack (call `deployFreshStack` first).
    ///         Pays the factory deployFee from `p.launcher`.
    function launchToken(LaunchParams memory p) internal returns (Launched memory l) {
        require(address(stack.factory) != address(0), "ForkStack: deployFreshStack first");
        IArtCoinsFactory.DeploymentConfig memory cfg = _buildConfig(p);
        uint256 fee = stack.factory.deployFee();
        vm.deal(p.launcher, p.launcher.balance + fee);
        vm.prank(p.launcher);
        if (p.taxBps == 0) {
            l.token = stack.factory.deployTokenWithProtocolBps{value: fee}(cfg, p.protocolBps);
        } else {
            l.token = stack.factory.deployTokenWithProtocolBpsAndTax{value: fee}(
                cfg, p.protocolBps, _taxConfig(p.taxBps)
            );
        }
        IArtCoinsLpLocker.TokenRewardInfo memory info = stack.locker.tokenRewards(l.token);
        l.key = info.poolKey;
        l.id = info.poolKey.toId();
        l.positionId = info.positionId;
        l.numPositions = info.numPositions;
        l.tickLower = cfg.lockerConfig.tickLower;
        l.tickUpper = cfg.lockerConfig.tickUpper;
        l.positionBps = cfg.lockerConfig.positionBps;
        vm.label(l.token, p.symbol);
    }

    function _buildConfig(LaunchParams memory p)
        internal
        view
        returns (IArtCoinsFactory.DeploymentConfig memory cfg)
    {
        cfg.tokenConfig = IArtCoinsFactory.TokenConfig({
            tokenAdmin: p.tokenAdmin,
            name: p.name,
            symbol: p.symbol,
            salt: p.salt,
            image: "",
            metadata: "",
            context: "v2 fork harness",
            totalSupply: p.totalSupply,
            renderer: address(0)
        });
        bytes memory feeData = abi.encode(
            IArtCoinsHookSkimFee.SkimHookFeeData({
                baselineSkimBps: p.baselineSkimBps,
                bountyBps: p.bountyBps,
                maxReferralBpsOfVolume: p.maxReferralBpsOfVolume,
                lpFee: p.lpFee,
                bountyRecipient: p.bountyRecipient,
                protocolRecipient: p.protocolRecipient,
                referralPayout: p.referralPayout,
                quoteToken: address(0)
            })
        );
        cfg.poolConfig = IArtCoinsFactory.PoolConfig({
            hook: address(stack.hook),
            pairedToken: address(0),
            tickIfToken0IsArtCoins: p.tickIfToken0IsArtCoins,
            tickSpacing: LaunchDefaults.TICK_SPACING,
            poolData: abi.encode(
                IArtCoinsHook.PoolInitializationData({
                    extension: address(0), extensionData: "", feeData: feeData
                })
            )
        });
        (int24[] memory lo, int24[] memory hi, uint16[] memory pb) =
            LaunchDefaults.buildLayerThinFloor12Positions(p.tickIfToken0IsArtCoins);
        cfg.lockerConfig = IArtCoinsFactory.LockerConfig({
            locker: address(stack.locker),
            rewardAdmins: p.rewardAdmins,
            rewardRecipients: p.rewardRecipients,
            rewardBps: p.rewardBps,
            tickLower: lo,
            tickUpper: hi,
            positionBps: pb,
            lockerData: ""
        });
        cfg.mevModuleConfig = IArtCoinsFactory.MevModuleConfig({
            mevModule: address(stack.mev), mevModuleData: p.mevModuleData
        });
        cfg.sniperFeeConfig = IArtCoinsFactory.SniperFeeConfig({recipient: address(0), lockRecipient: false});
        cfg.extensionConfigs = new IArtCoinsFactory.ExtensionConfig[](0);
    }

    /// @dev Mirrors the live 111 tax shape: max 2000, canonical pool = native
    ///      ETH / dynamic fee / spacing 200 on the fresh hook, no extra venues.
    function _taxConfig(uint16 taxBps) internal view returns (TaxConfig memory t) {
        t.enabled = true;
        t.taxBps = taxBps;
        t.taxBpsMax = 2000;
        t.burnAddress = 0x000000000000000000000000000000000000dEaD;
        t.poolManager = POOL_MANAGER;
        t.canonicalHook = address(stack.hook);
        t.pairedToken = address(0);
        t.canonicalPoolFee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        t.canonicalTickSpacing = LaunchDefaults.TICK_SPACING;
        t.exempt = new address[](0);
        t.venues = new TaxVenue[](0);
    }

    // ─── live stack ──────────────────────────────────────────────────────

    /// @notice Live current stack. The coin 111 pool key is read from the live
    ///         locker (`tokenRewards(COIN_111).poolKey`), so it tracks chain
    ///         state rather than a hardcoded key.
    function liveStack() internal view returns (LiveStack memory s) {
        s.factory = LIVE_FACTORY;
        s.hook = LIVE_HOOK;
        s.locker = LIVE_LOCKER;
        s.escrow = LIVE_ESCROW;
        s.mev = LIVE_MEV_SKIM;
        s.poolExtAllowlist = LIVE_POOL_EXT_ALLOWLIST;
        s.owner = LIVE_OWNER;
        s.olderFactory = OLDER_FACTORY;
        s.legacyFactory = LEGACY_FACTORY;
        s.coin111 = COIN_111;
        s.coin111Key = IArtCoinsLpLocker(LIVE_LOCKER).tokenRewards(COIN_111).poolKey;
        s.coin111Id = s.coin111Key.toId();
    }
}
