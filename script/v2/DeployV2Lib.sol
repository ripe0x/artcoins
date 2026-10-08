// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Constants} from "../../src/Constants.sol";
import {ArtCoinsPoolExtensionAllowlist} from "../../src/hooks/ArtCoinsPoolExtensionAllowlist.sol";
import {ArtCoinsFactoryV2} from "../../src/v2/ArtCoinsFactoryV2.sol";
import {ArtCoinsFeeEscrowV2} from "../../src/v2/ArtCoinsFeeEscrowV2.sol";
import {ArtCoinsHookV2} from "../../src/v2/hooks/ArtCoinsHookV2.sol";
import {IArtCoinsHookV2} from "../../src/v2/interfaces/IArtCoinsHookV2.sol";
import {ArtCoinsKeeperV2} from "../../src/v2/keepers/ArtCoinsKeeperV2.sol";
import {ArtCoinsLpLockerV2} from "../../src/v2/lp-lockers/ArtCoinsLpLockerV2.sol";
import {ArtCoinsMevLinearSkimV2} from "../../src/v2/mev-modules/ArtCoinsMevLinearSkimV2.sol";
import {BurnRouterV2} from "../../src/v2/protocol-fee/BurnRouterV2.sol";
import {ProtocolFeeControllerV2} from "../../src/v2/protocol-fee/ProtocolFeeControllerV2.sol";
import {ArtCoinsDeployerV2} from "../../src/v2/utils/ArtCoinsDeployerV2.sol";

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

/// @title  DeployV2Lib
/// @notice The one v2 stack deploy routine. `script/v2/DeployV2Stack.s.sol`
///         runs it inside `vm.startBroadcast()`; the fork harness
///         (`test/v2/harness/ForkStack.sol` `deployV2Stack`) runs it inside
///         `vm.startPrank(broadcaster)`. Same code, so tests and the script
///         cannot drift. Internal functions only: every `new` and call runs in
///         the caller's context (the broadcaster or the pranked address).
/// @dev    Order (DESIGN d7, DECISIONS D28, D33, D36, D38):
///          1 escrow                       owner = broadcaster (wired below)
///          2 extension allowlist          owner = OWNER (no deploy time owner call)
///          3 hook, CREATE2 via 0x4e59     salt mined for flags 0x28CC, owner = broadcaster
///          4 locker                       owner = broadcaster
///          5 linear skim module           ctor takes the hook, ownerless
///          6 factory                      owner = broadcaster, ships deprecated
///          7 token deployer               bound to the factory, then `setTokenDeployer`
///          8 burn router                  owner = OWNER, `initialize(coin, key)` later
///          9 protocol fee controller      owner = OWNER, treasury, burn router (ctor needs it, so 8 before 9)
///         10 keeper                       `ArtCoinsKeeperV2(factory)`, ownerless
///         11 wiring                       escrow depositors first (D36), then hook, locker, factory
///         12 ownership                    pending owner = OWNER on escrow, hook, locker, factory when the
///                                         broadcaster differs (Ownable2Step, `acceptOwnership` by OWNER)
///         `check` holds every post deploy assert (step 13 of the script).
library DeployV2Lib {
    // ── v2 hook address flags (DESIGN section 5) ────────────────────────────
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );
    uint160 internal constant HOOK_LOW_BITS = 0x28CC;
    uint256 internal constant MAX_MINE = 400_000;

    // ── defaults ────────────────────────────────────────────────────────────
    uint256 internal constant DEPLOY_FEE = 0.069 ether;
    uint16 internal constant PROTOCOL_BPS = 2000;
    /// @dev Controller split: the largest treasury share Constants allows
    ///      (PFC_MIN_BURN_BPS 1000). The burn share waits in the router until
    ///      `initialize(coin, key)`.
    uint16 internal constant TREASURY_BPS = 9000;
    /// @dev D52: the protocol keeps at least 10% of every skim; caps launch
    ///      bountyBps at 9000 and the referral cap above that floor.
    uint16 internal constant MIN_PROTOCOL_SKIM_SHARE_BPS = 1000;
    uint256 internal constant EIP170 = 24_576;

    /// @dev Deploy inputs. `referralPayout == 0` means "use the escrow": the
    ///      hook needs a payout with code; the escrow has no `notify`, so every
    ///      referral leg credits the referrer in the escrow (D16), claimable
    ///      with `escrow.claim(referrer, address(0))`. The live payout 0xB03C
    ///      answers `Unauthorized()` to any caller but the v1 hook 0x636c, and
    ///      the owner eoa has no code (hook init would revert), so neither is used.
    struct Params {
        address owner;
        address broadcaster;
        address poolManager;
        address positionManager;
        address permit2;
        address create2Deployer;
        address treasury;
        uint16 treasuryBps;
        address referralPayout;
        uint256 deployFee;
        uint16 protocolBps;
        uint16 minProtocolSkimShareBps;
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
        ArtCoinsKeeperV2 keeper;
    }

    /// @notice Mainnet infra plus the d7 defaults. `treasury` defaults to `owner`.
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
        p.referralPayout = address(0);
        p.deployFee = DEPLOY_FEE;
        p.protocolBps = PROTOCOL_BPS;
        p.minProtocolSkimShareBps = MIN_PROTOCOL_SKIM_SHARE_BPS;
        p.checkSizes = true;
    }

    // ══════════════════════════════════════════════════════════════════════
    // deploy
    // ══════════════════════════════════════════════════════════════════════

    function deploy(Params memory p) internal returns (Stack memory s) {
        require(p.owner != address(0) && p.broadcaster != address(0), "v2: zero owner");
        require(p.treasury != address(0), "v2: zero treasury");
        require(p.create2Deployer.code.length != 0, "v2: no CREATE2 deployer");
        require(p.poolManager.code.length != 0, "v2: no PoolManager");
        require(p.positionManager.code.length != 0, "v2: no PositionManager");

        // 1, 2
        s.escrow = new ArtCoinsFeeEscrowV2(p.broadcaster);
        s.allowlist = new ArtCoinsPoolExtensionAllowlist(p.owner);
        // 3
        (s.hook, s.hookSalt) = _deployHook(p, address(s.escrow), address(s.allowlist));
        // 4, 5
        s.locker =
            new ArtCoinsLpLockerV2(p.broadcaster, p.positionManager, p.permit2, address(s.escrow));
        s.mev = new ArtCoinsMevLinearSkimV2(address(s.hook));
        // 6, 7 (D38)
        s.factory = new ArtCoinsFactoryV2(p.broadcaster, p.poolManager, p.protocolBps, p.deployFee);
        s.tokenDeployer = new ArtCoinsDeployerV2(address(s.factory));
        s.factory.setTokenDeployer(address(s.tokenDeployer));
        // 8, 9
        s.burnRouter = new BurnRouterV2(p.owner, p.poolManager, address(s.escrow));
        s.controller = new ProtocolFeeControllerV2(
            p.owner, address(s.escrow), p.treasury, address(s.burnRouter), p.treasuryBps
        );
        // 10
        s.keeper = new ArtCoinsKeeperV2(address(s.factory));

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

    /// @dev Step 11. D36: the escrow knows the hook and locker as core
    ///      depositors before either `setFeeEscrow` (the hook's setter reverts
    ///      otherwise). D33: the controller is a non core depositor. D28: locker
    ///      keeper reward 0. The factory stays deprecated.
    function _wire(Stack memory s, Params memory p) private {
        s.escrow.addDepositor(address(s.hook), true);
        s.escrow.addDepositor(address(s.locker), true);
        s.escrow.addDepositor(address(s.controller), false);

        s.hook.setFeeEscrow(address(s.escrow));
        s.hook.setExtensionAllowlist(address(s.allowlist));
        s.hook.setLauncher(address(s.factory), true);

        s.locker.setFeeEscrow(address(s.escrow));
        s.locker.setLauncher(address(s.factory), true);
        s.locker.setKeeperRewardBps(0);

        address payout = p.referralPayout == address(0) ? address(s.escrow) : p.referralPayout;
        ArtCoinsFactoryV2 f = s.factory;
        f.setHook(address(s.hook), true);
        f.setLocker(address(s.locker), true);
        f.setMevModule(address(s.mev), true);
        f.setEscrow(address(s.escrow), true);
        f.setProtocolRecipient(payable(address(s.controller)));
        f.setReferralPayout(payable(payout));
        f.setTeamFeeRecipient(p.owner);
        f.setDeployFee(p.deployFee);
        f.setDefaultProtocolFeeBps(p.protocolBps);
        f.setMinProtocolSkimShareBps(p.minProtocolSkimShareBps);
        // defaultAllowed ships empty; see the allowlist rule on
        // ArtCoinsFactoryV2._defaultAllowed for what may be added.
        // deprecated stays true (constructor). opening is a separate owner tx.
    }

    /// @dev Step 12. Two step: OWNER must `acceptOwnership` on each.
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
            e.isDepositor(address(s.locker)) && e.isCoreDepositor(address(s.locker)),
            "v2: locker dep"
        );
        require(
            e.isDepositor(address(s.controller)) && !e.isCoreDepositor(address(s.controller)),
            "v2: controller dep"
        );
    }

    function _checkLocker(Stack memory s) private view {
        ArtCoinsLpLockerV2 l = s.locker;
        require(l.feeEscrow() == address(s.escrow), "v2: locker escrow");
        require(l.isLauncher(address(s.factory)), "v2: locker launcher");
        require(l.keeperRewardBps() == 0, "v2: locker keeper reward");
    }

    function _checkFactory(Stack memory s, Params memory p) private view {
        ArtCoinsFactoryV2 f = s.factory;
        address payout = p.referralPayout == address(0) ? address(s.escrow) : p.referralPayout;
        require(f.poolManager() == p.poolManager, "v2: factory PoolManager");
        require(f.tokenDeployer() == address(s.tokenDeployer), "v2: factory deployer");
        require(s.tokenDeployer.factory() == address(f), "v2: deployer binding");
        require(f.enabledHooks(address(s.hook)), "v2: factory hook");
        require(f.enabledLockers(address(s.locker)), "v2: factory locker");
        require(f.enabledMevModules(address(s.mev)), "v2: factory mev");
        require(f.enabledEscrows(address(s.escrow)), "v2: factory escrow");
        require(f.protocolRecipient() == address(s.controller), "v2: protocol recipient");
        require(f.referralPayout() == payout && payout.code.length != 0, "v2: referral payout");
        require(f.teamFeeRecipient() == p.owner, "v2: team fee recipient");
        require(f.deployFee() == p.deployFee, "v2: deploy fee");
        require(f.defaultProtocolFeeBps() == p.protocolBps, "v2: protocol bps");
        require(f.minProtocolSkimShareBps() == p.minProtocolSkimShareBps, "v2: min skim share");
        require(f.defaultAllowed().length == 0, "v2: default allowed must ship empty");
        require(f.deprecated(), "v2: factory must ship deprecated");
        require(f.STACK_VERSION() == Constants.STACK_VERSION, "v2: stack version");
    }

    function _checkPeriphery(Stack memory s, Params memory p) private view {
        require(s.mev.hook() == address(s.hook), "v2: mev hook");
        require(s.keeper.factory() == address(s.factory), "v2: keeper factory");
        require(s.controller.feeEscrow() == address(s.escrow), "v2: controller escrow");
        require(s.controller.treasury() == p.treasury, "v2: controller treasury");
        require(s.controller.burnRouter() == address(s.burnRouter), "v2: controller router");
        require(s.controller.treasuryBps() == p.treasuryBps, "v2: controller split");
        require(s.burnRouter.feeEscrow() == address(s.escrow), "v2: router escrow");
        require(address(s.burnRouter.poolManager()) == p.poolManager, "v2: router PoolManager");
        require(s.burnRouter.coin() == address(0), "v2: router initialized early");
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
        address[10] memory a = addresses(s);
        for (uint256 i; i < a.length; ++i) {
            uint256 n = a[i].code.length;
            require(n != 0 && n <= EIP170, "v2: runtime size over EIP-170 (use FOUNDRY_PROFILE=ci)");
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    // listing (script output, verify, tests)
    // ══════════════════════════════════════════════════════════════════════

    /// @notice Registry order. Names, source paths and roles in `names`, `paths`, `roles`.
    function addresses(Stack memory s) internal pure returns (address[10] memory a) {
        a[0] = address(s.escrow);
        a[1] = address(s.allowlist);
        a[2] = address(s.hook);
        a[3] = address(s.locker);
        a[4] = address(s.mev);
        a[5] = address(s.factory);
        a[6] = address(s.tokenDeployer);
        a[7] = address(s.burnRouter);
        a[8] = address(s.controller);
        a[9] = address(s.keeper);
    }

    function names() internal pure returns (string[10] memory n) {
        n[0] = "ArtCoinsFeeEscrowV2";
        n[1] = "ArtCoinsPoolExtensionAllowlist";
        n[2] = "ArtCoinsHookV2";
        n[3] = "ArtCoinsLpLockerV2";
        n[4] = "ArtCoinsMevLinearSkimV2";
        n[5] = "ArtCoinsFactoryV2";
        n[6] = "ArtCoinsDeployerV2";
        n[7] = "BurnRouterV2";
        n[8] = "ProtocolFeeControllerV2";
        n[9] = "ArtCoinsKeeperV2";
    }

    /// @dev Path qualified: `src/hooks/legacy/ArtCoinsHookV2.sol` has the same contract name.
    function paths() internal pure returns (string[10] memory n) {
        n[0] = "src/v2/ArtCoinsFeeEscrowV2.sol";
        n[1] = "src/hooks/ArtCoinsPoolExtensionAllowlist.sol";
        n[2] = "src/v2/hooks/ArtCoinsHookV2.sol";
        n[3] = "src/v2/lp-lockers/ArtCoinsLpLockerV2.sol";
        n[4] = "src/v2/mev-modules/ArtCoinsMevLinearSkimV2.sol";
        n[5] = "src/v2/ArtCoinsFactoryV2.sol";
        n[6] = "src/v2/utils/ArtCoinsDeployerV2.sol";
        n[7] = "src/v2/protocol-fee/BurnRouterV2.sol";
        n[8] = "src/v2/protocol-fee/ProtocolFeeControllerV2.sol";
        n[9] = "src/v2/keepers/ArtCoinsKeeperV2.sol";
    }

    /// @dev Registry roles (script-js/verify-registry.mjs ROLES).
    function roles() internal pure returns (string[10] memory n) {
        n[0] = "escrow";
        n[1] = "allowlist";
        n[2] = "hook";
        n[3] = "locker";
        n[4] = "mevModule";
        n[5] = "factory";
        n[6] = "other";
        n[7] = "router";
        n[8] = "controller";
        n[9] = "other";
    }

    /// @notice abi encoded constructor args, for `forge verify-contract`.
    function ctorArgs(Stack memory s, Params memory p) internal pure returns (bytes[10] memory a) {
        a[0] = abi.encode(p.broadcaster);
        a[1] = abi.encode(p.owner);
        a[2] = hookArgs(p, address(s.escrow), address(s.allowlist));
        a[3] = abi.encode(p.broadcaster, p.positionManager, p.permit2, address(s.escrow));
        a[4] = abi.encode(address(s.hook));
        a[5] = abi.encode(p.broadcaster, p.poolManager, p.protocolBps, p.deployFee);
        a[6] = abi.encode(address(s.factory));
        a[7] = abi.encode(p.owner, p.poolManager, address(s.escrow));
        a[8] = abi.encode(
            p.owner, address(s.escrow), p.treasury, address(s.burnRouter), p.treasuryBps
        );
        a[9] = abi.encode(address(s.factory));
    }
}
