// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Constants} from "../../src/Constants.sol";
import {ArtCoinsPoolExtensionAllowlist} from "../../src/hooks/ArtCoinsPoolExtensionAllowlist.sol";
import {ArtCoinsFactoryV2} from "../../src/v2/ArtCoinsFactoryV2.sol";
import {ArtCoinsFeeEscrowV2} from "../../src/v2/ArtCoinsFeeEscrowV2.sol";
import {ArtCoinsAirdropV2} from "../../src/v2/extensions/ArtCoinsAirdropV2.sol";
import {ArtCoinsUniv4EthDevBuyV2} from "../../src/v2/extensions/ArtCoinsUniv4EthDevBuyV2.sol";
import {ArtCoinsVaultV2} from "../../src/v2/extensions/ArtCoinsVaultV2.sol";
import {IArtCoinsAirdropV2} from "../../src/v2/extensions/interfaces/IArtCoinsAirdropV2.sol";
import {
    IArtCoinsUniv4EthDevBuyV2
} from "../../src/v2/extensions/interfaces/IArtCoinsUniv4EthDevBuyV2.sol";
import {IArtCoinsVaultV2} from "../../src/v2/extensions/interfaces/IArtCoinsVaultV2.sol";
import {ArtCoinsHookV2} from "../../src/v2/hooks/ArtCoinsHookV2.sol";
import {IArtCoinsHookV2} from "../../src/v2/interfaces/IArtCoinsHookV2.sol";
import {ArtCoinsLpLockerV2} from "../../src/v2/lp-lockers/ArtCoinsLpLockerV2.sol";
import {ArtCoinsMevLinearSkimV2} from "../../src/v2/mev-modules/ArtCoinsMevLinearSkimV2.sol";
import {BurnRouterV2} from "../../src/v2/protocol-fee/BurnRouterV2.sol";
import {ProtocolFeeControllerV2} from "../../src/v2/protocol-fee/ProtocolFeeControllerV2.sol";
import {ArtCoinsDeployerV2} from "../../src/v2/utils/ArtCoinsDeployerV2.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

/// @dev Fee getters on the LAYER pool hook.
interface ILayerHookFee {
    function protocolFeeNumerator() external view returns (uint256);
    function protocolFee() external view returns (uint256);
}

/// @title  DeployV2Lib
/// @notice The v2 stack deploy routine. `script/v2/DeployV2Stack.s.sol` runs it
///         inside `vm.startBroadcast()` and the fork harness runs it inside
///         `vm.startPrank(broadcaster)`. All functions are internal, so every
///         `new` and call runs in the caller's context.
/// @dev    Deploy order: escrow, extension allowlist, hook (CREATE2, mined salt), locker, mev
///         module, factory, token deployer, burn router, controller (its constructor takes the
///         router), dev buy extension, airdrop extension, vault extension, wiring, then the
///         pending owner transfer. `check` holds every post deploy assert.
library DeployV2Lib {
    // ── v2 hook address flags ───────────────────────────────────────────────
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );
    uint160 internal constant HOOK_LOW_BITS = 0x28CC;
    uint256 internal constant MAX_MINE = 400_000;

    // ── defaults ────────────────────────────────────────────────────────────
    /// @dev Launches are free at the v2 opening; the owner can set a fee later
    ///      (`setDeployFee`, up to MAX_DEPLOY_FEE).
    uint256 internal constant DEPLOY_FEE = 0;
    /// @dev Controller split at launch: 80% to the treasury, 20% buys and
    ///      burns LAYER. Owner tunable within [PFC_MIN_TREASURY_BPS, BPS - PFC_MIN_BURN_BPS].
    uint16 internal constant TREASURY_BPS = 8000;
    uint256 internal constant EIP170 = 24_576;
    /// @dev Required runtime code headroom under EIP-170 for the hook and the locker (RUNBOOK gate 4).
    uint256 internal constant HEADROOM = 1024;

    /// @dev Deploy inputs.
    struct Params {
        address owner;
        address broadcaster;
        address poolManager;
        address positionManager;
        address permit2;
        address create2Deployer;
        /// @dev Burn router binding: wrapped eth, the coin it burns (LAYER) and
        ///      the coin's weth pool key, read from the chain by the caller.
        address weth;
        address layer;
        PoolKey layerPoolKey;
        address treasury;
        uint16 treasuryBps;
        uint256 deployFee;
        /// @dev Enforce EIP-170 in `check`. Always true in the script. The
        ///      token deployer is over the limit at the default profile
        ///      (optimizer_runs 20000), so the stack ships from FOUNDRY_PROFILE=ci;
        ///      the fork harness turns this off under other profiles.
        bool checkSizes;
    }

    struct Stack {
        ArtCoinsFeeEscrowV2 escrow;
        ArtCoinsPoolExtensionAllowlist allowlist;
        ArtCoinsHookV2 hook;
        bytes32 hookSalt;
        ArtCoinsLpLockerV2 locker;
        ArtCoinsMevLinearSkimV2 mev;
        ArtCoinsFactoryV2 factory;
        ArtCoinsDeployerV2 tokenDeployer;
        BurnRouterV2 burnRouter;
        ProtocolFeeControllerV2 controller;
        ArtCoinsUniv4EthDevBuyV2 devBuy;
        ArtCoinsAirdropV2 airdrop;
        ArtCoinsVaultV2 vault;
    }

    /// @notice Mainnet infra plus the launch defaults. `treasury` defaults to `owner`.
    function defaults(
        address owner,
        address broadcaster,
        address poolManager,
        address positionManager,
        address permit2,
        address create2Deployer
    ) internal pure returns (Params memory p) {
        p.owner = owner;
        p.broadcaster = broadcaster;
        p.poolManager = poolManager;
        p.positionManager = positionManager;
        p.permit2 = permit2;
        p.create2Deployer = create2Deployer;
        p.treasury = owner;
        p.treasuryBps = TREASURY_BPS;
        p.deployFee = DEPLOY_FEE;
        p.checkSizes = true;
    }

    // ══════════════════════════════════════════════════════════════════════
    // deploy
    // ══════════════════════════════════════════════════════════════════════

    function deploy(Params memory p) internal returns (Stack memory s) {
        require(p.owner != address(0) && p.broadcaster != address(0), "v2: zero owner");
        require(p.treasury != address(0), "v2: zero treasury");
        require(p.weth.code.length != 0 && p.layer.code.length != 0, "v2: weth or layer missing");
        require(p.create2Deployer.code.length != 0, "v2: no CREATE2 deployer");
        require(p.poolManager.code.length != 0, "v2: no PoolManager");
        require(p.positionManager.code.length != 0, "v2: no PositionManager");

        // 1, 2
        s.escrow = new ArtCoinsFeeEscrowV2(p.broadcaster);
        s.allowlist = new ArtCoinsPoolExtensionAllowlist(p.owner);
        // 3
        (s.hook, s.hookSalt) = _deployHook(p, address(s.escrow), address(s.allowlist));
        // 4, 5
        s.locker = new ArtCoinsLpLockerV2(p.broadcaster, p.positionManager, p.permit2);
        s.mev = new ArtCoinsMevLinearSkimV2(address(s.hook));
        // 6, 7
        s.factory = new ArtCoinsFactoryV2(p.broadcaster, p.poolManager, p.deployFee);
        s.tokenDeployer = new ArtCoinsDeployerV2(address(s.factory));
        s.factory.setTokenDeployer(address(s.tokenDeployer));
        // 8, 9
        s.burnRouter = new BurnRouterV2(p.owner, p.poolManager, p.weth, p.layer, p.layerPoolKey);
        s.controller = new ProtocolFeeControllerV2(
            p.owner, address(s.escrow), p.treasury, address(s.burnRouter), p.treasuryBps
        );
        // 10, 11, 12
        s.devBuy = new ArtCoinsUniv4EthDevBuyV2(address(s.factory), p.poolManager);
        s.airdrop = new ArtCoinsAirdropV2(address(s.factory));
        s.vault = new ArtCoinsVaultV2(address(s.factory));
        _wire(s, p);
        _handOver(s, p);
    }

    /// @notice CREATE2 init code of the hook for `p` (salt search input, and
    ///         the verify step's constructor args).
    function hookArgs(Params memory p, address escrow, address allowlist)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(IPoolManager(p.poolManager), p.broadcaster, escrow, allowlist);
    }

    function _deployHook(Params memory p, address escrow, address allowlist)
        private
        returns (ArtCoinsHookV2 hook, bytes32 salt)
    {
        bytes memory initCode = abi.encodePacked(
            type(ArtCoinsHookV2).creationCode, hookArgs(p, escrow, allowlist)
        );
        address predicted;
        (predicted, salt) = mineHookSalt(p.create2Deployer, keccak256(initCode));
        // same formula as HookMiner, checked once on the result
        require(
            HookMiner.computeAddress(p.create2Deployer, uint256(salt), initCode) == predicted,
            "v2: miner formula"
        );
        (bool ok, bytes memory ret) = p.create2Deployer.call(abi.encodePacked(salt, initCode));
        require(ok && ret.length == 20 && address(bytes20(ret)) == predicted, "v2: hook CREATE2");
        hook = ArtCoinsHookV2(payable(predicted));
    }

    /// @notice Salt for the CREATE2 deployer whose address carries exactly the
    ///         v2 flags in its low 14 bits. Same search as `HookMiner.find`,
    ///         but the init code hash is computed once and code is checked
    ///         only on a match (a fork answers each code read over rpc).
    function mineHookSalt(address deployer, bytes32 initCodeHash)
        internal
        view
        returns (address hook, bytes32 salt)
    {
        for (uint256 i; i < MAX_MINE; ++i) {
            hook = address(
                uint160(
                    uint256(keccak256(abi.encodePacked(bytes1(0xFF), deployer, i, initCodeHash)))
                )
            );
            if (uint160(hook) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS && hook.code.length == 0) {
                return (hook, bytes32(i));
            }
        }
        revert("v2: no hook salt");
    }

    /// @dev Step 13. The hook is a core escrow depositor before `setFeeEscrow`,
    ///      whose setter reverts otherwise. The controller is a non core depositor.
    ///      The dev buy, airdrop and vault extensions are enabled on the factory.
    ///      The factory stays deprecated.
    function _wire(Stack memory s, Params memory p) private {
        s.escrow.addDepositor(address(s.hook), true);
        s.escrow.addDepositor(address(s.controller), false);

        s.hook.setFeeEscrow(address(s.escrow));
        s.hook.setExtensionAllowlist(address(s.allowlist));
        s.hook.setLauncher(address(s.factory), true);

        s.locker.setLauncher(address(s.factory), true);

        ArtCoinsFactoryV2 f = s.factory;
        f.setHook(address(s.hook), true);
        f.setLocker(address(s.locker), true);
        f.setMevModule(address(s.mev), true);
        f.setProtocolRecipient(payable(address(s.controller)));
        f.setTeamFeeRecipient(p.owner);
        f.setDeployFee(p.deployFee);
        f.setExtension(address(s.devBuy), true);
        f.setExtension(address(s.airdrop), true);
        f.setExtension(address(s.vault), true);
        // deprecated stays true (constructor). opening is a separate owner tx.
    }

    /// @dev Step 14. Two step: OWNER must `acceptOwnership` on each.
    function _handOver(Stack memory s, Params memory p) private {
        if (p.owner == p.broadcaster) return;
        s.escrow.transferOwnership(p.owner);
        s.hook.transferOwnership(p.owner);
        s.locker.transferOwnership(p.owner);
        s.factory.transferOwnership(p.owner);
    }

    /// @notice The four contracts OWNER accepts when the broadcaster differs.
    function pendingOwnables(Stack memory s) internal pure returns (Ownable2Step[4] memory o) {
        o[0] = Ownable2Step(address(s.escrow));
        o[1] = Ownable2Step(address(s.hook));
        o[2] = Ownable2Step(address(s.locker));
        o[3] = Ownable2Step(address(s.factory));
    }

    // ══════════════════════════════════════════════════════════════════════
    // post deploy asserts
    // ══════════════════════════════════════════════════════════════════════

    /// @notice Every post deploy assert. Reverts with the first failure.
    ///         `accepted`: OWNER already called `acceptOwnership` (or deployed).
    function check(Stack memory s, Params memory p, bool accepted) internal view {
        _checkConstants(s);
        _checkHook(s, p);
        _checkEscrow(s);
        _checkLocker(s);
        _checkFactory(s, p);
        _checkPeriphery(s, p);
        _checkLayerHook(s);
        _checkOwners(s, p, accepted);
        if (p.checkSizes) _checkSizes(s);
    }

    function _checkConstants(Stack memory s) private pure {
        bytes32 h = Constants.hash();
        require(s.escrow.constantsHash() == h, "v2: escrow constantsHash");
        require(s.hook.constantsHash() == h, "v2: hook constantsHash");
        require(s.locker.constantsHash() == h, "v2: locker constantsHash");
        require(s.mev.constantsHash() == h, "v2: mev constantsHash");
        require(s.factory.constantsHash() == h, "v2: factory constantsHash");
        require(s.tokenDeployer.constantsHash() == h, "v2: deployer constantsHash");
        require(s.burnRouter.constantsHash() == h, "v2: router constantsHash");
        require(s.controller.constantsHash() == h, "v2: controller constantsHash");
        require(s.devBuy.constantsHash() == h, "v2: dev buy constantsHash");
        require(s.airdrop.constantsHash() == h, "v2: airdrop constantsHash");
        require(s.vault.constantsHash() == h, "v2: vault constantsHash");
    }

    function _checkHook(Stack memory s, Params memory p) private view {
        address h = address(s.hook);
        require(uint160(h) & Hooks.ALL_HOOK_MASK == HOOK_LOW_BITS, "v2: hook low bits");
        Hooks.Permissions memory perms = s.hook.getHookPermissions();
        // reverts HookAddressNotValid when the address and the declared permissions differ
        Hooks.validateHookPermissions(IHooks(h), perms);
        require(
            perms.beforeInitialize && !perms.afterInitialize && perms.beforeAddLiquidity
                && !perms.afterAddLiquidity && !perms.beforeRemoveLiquidity
                && !perms.afterRemoveLiquidity && perms.beforeSwap && perms.afterSwap
                && !perms.beforeDonate && !perms.afterDonate && perms.beforeSwapReturnDelta
                && perms.afterSwapReturnDelta && !perms.afterAddLiquidityReturnDelta
                && !perms.afterRemoveLiquidityReturnDelta,
            "v2: hook permissions"
        );
        require(address(s.hook.poolManager()) == p.poolManager, "v2: hook PoolManager");
        IArtCoinsHookV2.HookGlobals memory g = s.hook.globals();
        require(g.feeEscrow == address(s.escrow), "v2: hook escrow");
        require(g.extensionAllowlist == address(s.allowlist), "v2: hook allowlist");
        require(s.hook.isLauncher(address(s.factory)), "v2: hook launcher");
    }

    function _checkEscrow(Stack memory s) private view {
        ArtCoinsFeeEscrowV2 e = s.escrow;
        require(
            e.isDepositor(address(s.hook)) && e.isCoreDepositor(address(s.hook)), "v2: hook dep"
        );
        require(
            e.isDepositor(address(s.controller)) && !e.isCoreDepositor(address(s.controller)),
            "v2: controller dep"
        );
    }

    function _checkLocker(Stack memory s) private view {
        require(s.locker.isLauncher(address(s.factory)), "v2: locker launcher");
    }

    function _checkFactory(Stack memory s, Params memory p) private view {
        ArtCoinsFactoryV2 f = s.factory;
        require(f.poolManager() == p.poolManager, "v2: factory PoolManager");
        require(f.tokenDeployer() == address(s.tokenDeployer), "v2: factory deployer");
        require(s.tokenDeployer.factory() == address(f), "v2: deployer binding");
        require(f.enabledHooks(address(s.hook)), "v2: factory hook");
        require(f.enabledLockers(address(s.locker)), "v2: factory locker");
        require(f.enabledMevModules(address(s.mev)), "v2: factory mev");
        require(f.enabledExtensions(address(s.devBuy)), "v2: factory dev buy");
        require(f.enabledExtensions(address(s.airdrop)), "v2: factory airdrop");
        require(f.enabledExtensions(address(s.vault)), "v2: factory vault");
        require(s.devBuy.factory() == address(f), "v2: dev buy factory");
        require(address(s.devBuy.poolManager()) == p.poolManager, "v2: dev buy PoolManager");
        require(s.airdrop.factory() == address(f), "v2: airdrop factory");
        require(s.vault.factory() == address(f), "v2: vault factory");
        _checkExtensionIds(s);
        require(f.protocolRecipient() == address(s.controller), "v2: protocol recipient");
        require(f.teamFeeRecipient() == p.owner, "v2: team fee recipient");
        require(f.deployFee() == p.deployFee, "v2: deploy fee");
        require(f.deprecated(), "v2: factory must ship deprecated");
        require(f.STACK_VERSION() == Constants.STACK_VERSION, "v2: stack version");
    }

    /// @dev Each extension address supports its own interface id and the other two extensions' ids are
    ///      unsupported. The factory binding and constants hash are identical across the three.
    function _checkExtensionIds(Stack memory s) private view {
        bytes4 d = type(IArtCoinsUniv4EthDevBuyV2).interfaceId;
        bytes4 a = type(IArtCoinsAirdropV2).interfaceId;
        bytes4 v = type(IArtCoinsVaultV2).interfaceId;
        IERC165 dev = IERC165(address(s.devBuy));
        IERC165 air = IERC165(address(s.airdrop));
        IERC165 vau = IERC165(address(s.vault));
        require(
            dev.supportsInterface(d) && !dev.supportsInterface(a) && !dev.supportsInterface(v),
            "v2: dev buy interface"
        );
        require(
            air.supportsInterface(a) && !air.supportsInterface(d) && !air.supportsInterface(v),
            "v2: airdrop interface"
        );
        require(
            vau.supportsInterface(v) && !vau.supportsInterface(d) && !vau.supportsInterface(a),
            "v2: vault interface"
        );
    }

    function _checkPeriphery(Stack memory s, Params memory p) private view {
        require(s.mev.hook() == address(s.hook), "v2: mev hook");
        require(s.controller.feeEscrow() == address(s.escrow), "v2: controller escrow");
        require(s.controller.treasury() == p.treasury, "v2: controller treasury");
        require(s.controller.burnRouter() == address(s.burnRouter), "v2: controller router");
        require(s.controller.treasuryBps() == p.treasuryBps, "v2: controller split");
        require(address(s.burnRouter.poolManager()) == p.poolManager, "v2: router PoolManager");
        require(s.burnRouter.weth() == p.weth, "v2: router weth");
        require(s.burnRouter.coin() == p.layer, "v2: router coin");
        require(
            keccak256(abi.encode(s.burnRouter.poolKey())) == keccak256(abi.encode(p.layerPoolKey)),
            "v2: router pool key"
        );
        // the controller binds the same coin and PoolManager as the router
        require(s.controller.coin() == p.layer, "v2: controller coin");
        require(s.controller.poolManager() == p.poolManager, "v2: controller PoolManager");
        // locker position and permit2 bindings
        require(
            address(s.locker.positionManager()) == p.positionManager, "v2: locker PositionManager"
        );
        require(address(s.locker.permit2()) == p.permit2, "v2: locker permit2");
        // router tunables at the approved deployment values
        BurnRouterV2 r = s.burnRouter;
        require(r.maxImpactBps() == Constants.PRICE_IMPACT_DEFAULT, "v2: router maxImpactBps");
        require(r.spotFloorBps() == Constants.BURN_SPOT_FLOOR_BPS, "v2: router spotFloorBps");
        require(r.keeperTip() == Constants.BURN_TIP_DEFAULT, "v2: router keeperTip");
        require(
            r.keeperGasOverhead() == Constants.BURN_GAS_OVERHEAD_DEFAULT,
            "v2: router keeperGasOverhead"
        );
        require(
            r.rewardMaxBaseFee() == Constants.BURN_BASEFEE_GATE_DEFAULT,
            "v2: router rewardMaxBaseFee"
        );
        require(r.rewardMaxBps() == Constants.BURN_REWARD_BPS_DEFAULT, "v2: router rewardMaxBps");
    }

    /// @dev Deployment policy: the LAYER pool hook charges no protocol fee. The router reads the
    ///      hook's stored `protocolFee()` at burn time and accounts for it in the floor, so a
    ///      nonzero value would not break the burn, but the deployment is approved at zero.
    ///      The numerator is the fee policy, the stored quote is the value the swap path charges.
    function _checkLayerHook(Stack memory s) private view {
        address hook = address(s.burnRouter.poolKey().hooks);
        if (block.chainid == 1 || hook.code.length != 0) {
            require(ILayerHookFee(hook).protocolFeeNumerator() == 0, "v2: LAYER hook protocol fee");
            require(ILayerHookFee(hook).protocolFee() == 0, "v2: LAYER hook stored protocolFee");
        }
    }

    function _checkOwners(Stack memory s, Params memory p, bool accepted) private view {
        Ownable2Step[4] memory o = pendingOwnables(s);
        bool direct = accepted || p.owner == p.broadcaster;
        for (uint256 i; i < 4; ++i) {
            if (direct) {
                require(o[i].owner() == p.owner && o[i].pendingOwner() == address(0), "v2: owner");
            } else {
                require(
                    o[i].owner() == p.broadcaster && o[i].pendingOwner() == p.owner,
                    "v2: pending owner"
                );
            }
        }
        require(s.allowlist.owner() == p.owner, "v2: allowlist owner");
        require(s.burnRouter.owner() == p.owner, "v2: router owner");
        require(s.controller.owner() == p.owner, "v2: controller owner");
    }

    function _checkSizes(Stack memory s) private view {
        address[12] memory a = addresses(s);
        for (uint256 i; i < a.length; ++i) {
            uint256 n = a[i].code.length;
            require(n != 0 && n <= EIP170, "v2: runtime size over EIP-170 (use FOUNDRY_PROFILE=ci)");
        }
        require(address(s.hook).code.length <= EIP170 - HEADROOM, "v2: hook size headroom");
        require(address(s.locker).code.length <= EIP170 - HEADROOM, "v2: locker size headroom");
    }

    // ══════════════════════════════════════════════════════════════════════
    // listing (script output, verify, tests)
    // ══════════════════════════════════════════════════════════════════════

    /// @notice Registry order. Names, source paths and roles in `names`, `paths`, `roles`.
    function addresses(Stack memory s) internal pure returns (address[12] memory a) {
        a[0] = address(s.escrow);
        a[1] = address(s.allowlist);
        a[2] = address(s.hook);
        a[3] = address(s.locker);
        a[4] = address(s.mev);
        a[5] = address(s.factory);
        a[6] = address(s.tokenDeployer);
        a[7] = address(s.burnRouter);
        a[8] = address(s.controller);
        a[9] = address(s.devBuy);
        a[10] = address(s.airdrop);
        a[11] = address(s.vault);
    }

    function names() internal pure returns (string[12] memory n) {
        n[0] = "ArtCoinsFeeEscrowV2";
        n[1] = "ArtCoinsPoolExtensionAllowlist";
        n[2] = "ArtCoinsHookV2";
        n[3] = "ArtCoinsLpLockerV2";
        n[4] = "ArtCoinsMevLinearSkimV2";
        n[5] = "ArtCoinsFactoryV2";
        n[6] = "ArtCoinsDeployerV2";
        n[7] = "BurnRouterV2";
        n[8] = "ProtocolFeeControllerV2";
        n[9] = "ArtCoinsUniv4EthDevBuyV2";
        n[10] = "ArtCoinsAirdropV2";
        n[11] = "ArtCoinsVaultV2";
    }

    /// @dev Path qualified: `src/hooks/legacy/ArtCoinsHookV2.sol` has the same contract name.
    function paths() internal pure returns (string[12] memory n) {
        n[0] = "src/v2/ArtCoinsFeeEscrowV2.sol";
        n[1] = "src/hooks/ArtCoinsPoolExtensionAllowlist.sol";
        n[2] = "src/v2/hooks/ArtCoinsHookV2.sol";
        n[3] = "src/v2/lp-lockers/ArtCoinsLpLockerV2.sol";
        n[4] = "src/v2/mev-modules/ArtCoinsMevLinearSkimV2.sol";
        n[5] = "src/v2/ArtCoinsFactoryV2.sol";
        n[6] = "src/v2/utils/ArtCoinsDeployerV2.sol";
        n[7] = "src/v2/protocol-fee/BurnRouterV2.sol";
        n[8] = "src/v2/protocol-fee/ProtocolFeeControllerV2.sol";
        n[9] = "src/v2/extensions/ArtCoinsUniv4EthDevBuyV2.sol";
        n[10] = "src/v2/extensions/ArtCoinsAirdropV2.sol";
        n[11] = "src/v2/extensions/ArtCoinsVaultV2.sol";
    }

    /// @dev Registry roles (script-js/verify-registry.mjs ROLES).
    function roles() internal pure returns (string[12] memory n) {
        n[0] = "escrow";
        n[1] = "allowlist";
        n[2] = "hook";
        n[3] = "locker";
        n[4] = "mevModule";
        n[5] = "factory";
        n[6] = "other";
        n[7] = "router";
        n[8] = "controller";
        n[9] = "extension";
        n[10] = "extension";
        n[11] = "extension";
    }

    /// @notice abi encoded constructor args, for `forge verify-contract`.
    function ctorArgs(Stack memory s, Params memory p) internal pure returns (bytes[12] memory a) {
        a[0] = abi.encode(p.broadcaster);
        a[1] = abi.encode(p.owner);
        a[2] = hookArgs(p, address(s.escrow), address(s.allowlist));
        a[3] = abi.encode(p.broadcaster, p.positionManager, p.permit2);
        a[4] = abi.encode(address(s.hook));
        a[5] = abi.encode(p.broadcaster, p.poolManager, p.deployFee);
        a[6] = abi.encode(address(s.factory));
        a[7] = abi.encode(p.owner, p.poolManager, p.weth, p.layer, p.layerPoolKey);
        a[8] = abi.encode(
            p.owner, address(s.escrow), p.treasury, address(s.burnRouter), p.treasuryBps
        );
        a[9] = abi.encode(address(s.factory), p.poolManager);
        a[10] = abi.encode(address(s.factory));
        a[11] = abi.encode(address(s.factory));
    }
}
