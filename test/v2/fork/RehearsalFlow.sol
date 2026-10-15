// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {DeployV2Lib} from "../../../script/v2/DeployV2Lib.sol";
import {LaunchV2Lib} from "../../../script/v2/LaunchV2Coin.s.sol";
import {Constants} from "../../../src/Constants.sol";
import {IArtCoinsHook} from "../../../src/interfaces/IArtCoinsHook.sol";
import {IArtCoinsAirdropV2} from "../../../src/v2/extensions/interfaces/IArtCoinsAirdropV2.sol";
import {
    IArtCoinsUniv4EthDevBuyV2
} from "../../../src/v2/extensions/interfaces/IArtCoinsUniv4EthDevBuyV2.sol";
import {IArtCoinsVaultV2} from "../../../src/v2/extensions/interfaces/IArtCoinsVaultV2.sol";
import {IArtCoinsFactoryV2} from "../../../src/v2/interfaces/IArtCoinsFactoryV2.sol";
import {IArtCoinsFeeEscrowV2} from "../../../src/v2/interfaces/IArtCoinsFeeEscrowV2.sol";
import {IArtCoinsHookV2} from "../../../src/v2/interfaces/IArtCoinsHookV2.sol";
import {IArtCoinsLpLockerV2} from "../../../src/v2/interfaces/IArtCoinsLpLockerV2.sol";
import {IBurnRouterV2} from "../../../src/v2/interfaces/IBurnRouterV2.sol";
import {BurnRouterV2} from "../../../src/v2/protocol-fee/BurnRouterV2.sol";
import {ProtocolFeeControllerV2} from "../../../src/v2/protocol-fee/ProtocolFeeControllerV2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

struct FcExactIn {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    bytes hookData;
}

interface IFcUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline)
        external
        payable;
}

interface IFcPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// Treasury stand in: accepts eth within the 2300 gas stipend.
contract FcTreasury {
    receive() external payable virtual {}
}

/// Recipient that reverts on eth, so the hook falls back to the escrow.
contract FcRejecter {
    function claimTo(IArtCoinsFeeEscrowV2 e, address to) external {
        e.claimTo(address(this), address(0), payable(to));
    }
}

/// @notice RUNBOOK gate 7 sequence, shared by the rehearsal against the deployed stack and the
///         rehearsal against a freshly deployed stack: launch, swaps through the Universal Router,
///         escrow claim, `processFees()`, `processBurn(minOut)`.
abstract contract RehearsalFlow is Test {
    using PoolIdLibrary for PoolKey;

    address internal constant FC_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant FC_UR = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address internal constant FC_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    uint256 internal constant FC_TX_CAP = 16_700_000;

    /// @dev Addresses of one v2 stack.
    struct Rig {
        IArtCoinsFactoryV2 factory;
        address hook;
        address locker;
        address mev;
        IArtCoinsFeeEscrowV2 escrow;
        ProtocolFeeControllerV2 controller;
        BurnRouterV2 router;
        address layer;
        /// @dev Sender of the launch (factory owner while the factory is deprecated).
        address launcher;
        /// @dev Launch extension instances of the stack. Zero when the stack has none.
        address devBuy;
        address airdrop;
        address vault;
    }

    /// @dev Two leaf airdrop tree, the dev buy parties and the vault beneficiary built by `_addExtensions`.
    struct ExtensionFixture {
        address vaultBeneficiary;
        address recipient;
        address refundRecipient;
        address leafA;
        address leafB;
        uint256 amountA;
        uint256 amountB;
        bytes32 hashA;
        bytes32 hashB;
        bytes32 root;
    }

    uint256 internal constant FC_DEV_BUY_ETH = 0.01 ether;
    uint16 internal constant FC_AIRDROP_BPS = 100;
    uint16 internal constant FC_VAULT_BPS = 50;
    uint256 internal constant FC_VAULT_LOCKUP = 7 days;
    uint256 internal constant FC_VAULT_VESTING = 90 days;

    ExtensionFixture internal fx;

    receive() external payable virtual {}

    function _target(Rig memory r) internal pure returns (LaunchV2Lib.Target memory t) {
        t = LaunchV2Lib.Target(
            address(r.factory), r.hook, r.locker, r.mev, r.devBuy, r.airdrop, r.vault
        );
    }

    // ── launch extensions ─────────────────────────────────────────────────

    /// @dev Replaces `l.cfg.extensions` with a dev buy of `FC_DEV_BUY_ETH` a 1% airdrop
    ///      (no lockup, no vesting) over a two leaf tree, and a 0.5% vault (7 day cliff, 90 day
    ///      vesting). Sweep recipient is the launcher.
    function _addExtensions(Rig memory r, LaunchV2Lib.Launch memory l) internal {
        fx.recipient = makeAddr("rehearsal.devBuyRecipient");
        fx.refundRecipient = makeAddr("rehearsal.devBuyRefund");
        fx.vaultBeneficiary = makeAddr("rehearsal.vaultBeneficiary");
        fx.leafA = makeAddr("rehearsal.airdropA");
        fx.leafB = makeAddr("rehearsal.airdropB");
        fx.amountA = 1000 ether;
        fx.amountB = 2000 ether;
        fx.hashA = keccak256(bytes.concat(keccak256(abi.encode(uint256(0), fx.leafA, fx.amountA))));
        fx.hashB = keccak256(bytes.concat(keccak256(abi.encode(uint256(1), fx.leafB, fx.amountB))));
        bytes32 root = fx.root = fx.hashA < fx.hashB
            ? keccak256(abi.encodePacked(fx.hashA, fx.hashB))
            : keccak256(abi.encodePacked(fx.hashB, fx.hashA));

        IArtCoinsFactoryV2.ExtensionConfigV2[] memory e =
            new IArtCoinsFactoryV2.ExtensionConfigV2[](3);
        e[0] = IArtCoinsFactoryV2.ExtensionConfigV2({
            extension: r.devBuy,
            msgValue: FC_DEV_BUY_ETH,
            extensionBps: 0,
            extensionData: abi.encode(fx.recipient, fx.refundRecipient, uint128(1))
        });
        e[1] = IArtCoinsFactoryV2.ExtensionConfigV2({
            extension: r.airdrop,
            msgValue: 0,
            extensionBps: FC_AIRDROP_BPS,
            extensionData: abi.encode(r.launcher, root, uint256(0), uint256(0))
        });
        e[2] = IArtCoinsFactoryV2.ExtensionConfigV2({
            extension: r.vault,
            msgValue: 0,
            extensionBps: FC_VAULT_BPS,
            extensionData: abi.encode(fx.vaultBeneficiary, FC_VAULT_LOCKUP, FC_VAULT_VESTING)
        });
        l.cfg.extensions = e;
    }

    /// @dev Effects of the configured dev buy and airdrop entries, read from the launch logs.
    function _checkExtensionEffects(
        Rig memory r,
        LaunchV2Lib.Launch memory l,
        Vm.Log[] memory logs,
        address token
    ) internal {
        for (uint256 k; k < l.cfg.extensions.length; ++k) {
            address ext = l.cfg.extensions[k].extension;
            if (ext == address(0)) continue;
            IArtCoinsFactoryV2.ExtensionConfigV2 memory e = l.cfg.extensions[k];
            if (ext == r.devBuy) _checkDevBuy(r, logs, token, e);
            if (ext == r.airdrop) _checkAirdrop(r, logs, token, k, e);
            if (ext == r.vault) _checkVault(r, logs, token, k, e);
        }
    }

    function _checkDevBuy(
        Rig memory r,
        Vm.Log[] memory logs,
        address token,
        IArtCoinsFactoryV2.ExtensionConfigV2 memory e
    ) internal view {
        (address recipient, address refundRecipient,) =
            abi.decode(e.extensionData, (address, address, uint128));
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != r.devBuy) continue;
            if (logs[i].topics[0] != IArtCoinsUniv4EthDevBuyV2.EthDevBuy.selector) continue;
            ++n;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), token, "dev buy token");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), recipient, "dev buy recipient");
            (uint256 spent, uint256 out, uint256 refunded, address refundTo) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, address));
            assertEq(refundTo, refundRecipient, "dev buy refund recipient");
            assertEq(spent + refunded, e.msgValue, "dev buy eth accounted");
            assertGt(out, 0, "dev buy out");
            assertEq(IERC20(token).balanceOf(recipient), out, "dev buy recipient coin balance");
            assertEq(refundRecipient.balance, refunded, "refund recipient eth");
            // a full fill refunds nothing and credits no skim
            assertEq(refunded, 0, "full fill: no refund");
            assertEq(r.escrow.balances(refundRecipient, address(0)), 0, "refund escrow credit");
        }
        assertEq(n, 1, "one EthDevBuy");
        assertEq(r.devBuy.balance, 0, "dev buy holds no eth");
        assertEq(r.escrow.balances(r.devBuy, address(0)), 0, "dev buy holds no escrow credit");
    }

    function _checkAirdrop(
        Rig memory r,
        Vm.Log[] memory logs,
        address token,
        uint256 index,
        IArtCoinsFactoryV2.ExtensionConfigV2 memory e
    ) internal {
        (address sweepRecipient, bytes32 root,,) =
            abi.decode(e.extensionData, (address, bytes32, uint256, uint256));
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != r.airdrop) continue;
            if (logs[i].topics[0] != IArtCoinsAirdropV2.AirdropCreated.selector) continue;
            ++n;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), token, "airdrop token");
            assertEq(uint256(logs[i].topics[2]), index, "airdrop index");
            assertEq(
                address(uint160(uint256(logs[i].topics[3]))),
                sweepRecipient,
                "airdrop sweep recipient"
            );
        }
        assertEq(n, 1, "one AirdropCreated");
        IArtCoinsAirdropV2 air = IArtCoinsAirdropV2(r.airdrop);
        uint256 supply = IERC20(token).totalSupply() * e.extensionBps / Constants.BPS;
        assertEq(air.tranche(token, index).supply, supply, "tranche supply");
        assertEq(IERC20(token).balanceOf(r.airdrop), supply, "airdrop holds its share");

        // the claim round trip needs the fixture tree
        if (root != fx.root) return;
        // leaf A (index 0) claims with leaf B (index 1) as proof, then claiming again reverts
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = fx.hashB;
        assertEq(air.amountAvailableToClaim(token, index, 0, fx.amountA), fx.amountA);
        air.claim(token, index, 0, fx.leafA, fx.amountA, proof);
        assertEq(IERC20(token).balanceOf(fx.leafA), fx.amountA, "leaf A paid");
        assertEq(air.leafClaimed(token, index, 0), fx.amountA, "leaf A claimed");
        vm.expectRevert(IArtCoinsAirdropV2.UserMaxClaimed.selector);
        air.claim(token, index, 0, fx.leafA, fx.amountA, proof);
    }

    function _checkVault(
        Rig memory r,
        Vm.Log[] memory logs,
        address token,
        uint256 index,
        IArtCoinsFactoryV2.ExtensionConfigV2 memory e
    ) internal {
        (address beneficiary, uint256 lockup, uint256 vesting) =
            abi.decode(e.extensionData, (address, uint256, uint256));
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != r.vault) continue;
            if (logs[i].topics[0] != IArtCoinsVaultV2.AllocationCreated.selector) continue;
            ++n;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), token, "vault token");
        }
        assertEq(n, 1, "one AllocationCreated");
        IArtCoinsVaultV2 vault = IArtCoinsVaultV2(r.vault);
        uint256 amount = IERC20(token).totalSupply() * e.extensionBps / Constants.BPS;
        assertEq(IERC20(token).balanceOf(r.vault), amount, "vault holds its share");
        IArtCoinsVaultV2.Allocation memory a = vault.allocation(token, index);
        assertEq(a.beneficiary, beneficiary, "vault beneficiary");
        assertEq(a.amountTotal, amount, "vault amount");
        assertEq(a.lockupEndTime, block.timestamp + lockup, "vault lockup end");
        assertEq(a.vestingEndTime, a.lockupEndTime + vesting, "vault vesting end");

        // time travel is reverted so the later trading steps run at launch time
        uint256 snap = vm.snapshotState();
        vm.expectRevert(IArtCoinsVaultV2.AllocationNotUnlocked.selector);
        vault.claim(token, index);
        vm.warp(a.vestingEndTime);
        assertEq(vault.amountAvailableToClaim(token, index), amount, "fully vested");
        vm.expectEmit(true, true, true, true, r.vault);
        emit IArtCoinsVaultV2.AllocationClaimed(token, index, beneficiary, amount, 0);
        vault.claim(token, index);
        assertEq(IERC20(token).balanceOf(beneficiary), amount, "beneficiary paid");
        assertEq(IERC20(token).balanceOf(r.vault), 0, "vault emptied");
        vm.revertToState(snap);
    }

    // ── launch ────────────────────────────────────────────────────────────

    /// @dev Launches `l` from `r.launcher`, asserts the launch record, returns the coin and its pool.
    function _launchChecked(Rig memory r, LaunchV2Lib.Launch memory l)
        internal
        returns (address token, PoolKey memory key)
    {
        LaunchV2Lib.Target memory t = _target(r);
        (address predicted, uint256 value) = LaunchV2Lib.preflight(t, l, r.launcher);
        bytes32 cfgHash = r.factory.configHash(l.cfg);
        vm.deal(r.launcher, r.launcher.balance + value);

        vm.recordLogs();
        vm.prank(r.launcher);
        uint256 g = gasleft();
        token = r.factory.deployToken{value: value}(l.cfg);
        g -= gasleft();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        console2.log("launch gas", g);
        console2.log("launch gas headroom to 16.7M cap", FC_TX_CAP > g ? FC_TX_CAP - g : 0);
        assertLt(g, FC_TX_CAP, "launch gas above tx cap");
        assertEq(token, predicted, "token != predicted");
        PoolId pid = LaunchV2Lib.checkLaunched(t, l, token);
        assertTrue(r.factory.isCoin(token), "isCoin");
        assertEq(IArtCoinsHookV2(r.hook).poolInfo(pid).version, 2, "hook version");
        key = IArtCoinsLpLockerV2(r.locker).lockedLiquidity(token).poolKey;
        assertEq(PoolId.unwrap(key.toId()), PoolId.unwrap(pid), "pool id");

        _checkCreatedEvent(r, logs, token, pid, cfgHash);
        _checkExtensions(r, l, logs, token);
        _checkExtensionEffects(r, l, logs, token);
    }

    function _checkCreatedEvent(
        Rig memory r,
        Vm.Log[] memory logs,
        address token,
        PoolId pid,
        bytes32 cfgHash
    ) internal view {
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(r.factory)) continue;
            if (logs[i].topics[0] != IArtCoinsFactoryV2.TokenCreatedV2.selector) continue;
            ++n;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), r.launcher, "event sender");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), token, "event token");
            assertEq(logs[i].topics[3], PoolId.unwrap(pid), "event poolId");
            (
                uint16 stackVersion,
                bytes32 h,
                address protocolRecipient,
                uint256 poolSupply,
                uint256 extensionsSupply
            ) = abi.decode(logs[i].data, (uint16, bytes32, address, uint256, uint256));
            assertEq(stackVersion, Constants.STACK_VERSION, "event stackVersion");
            assertEq(h, cfgHash, "event configHash");
            assertEq(protocolRecipient, address(r.controller), "event protocolRecipient");
            assertEq(
                poolSupply + extensionsSupply, IERC20(token).totalSupply(), "event supply split"
            );
        }
        assertEq(n, 1, "one TokenCreatedV2");
    }

    /// @dev One ExtensionTriggered per configured extension (airdrop, vault, dev buy) in config
    ///      order, with its supply floor and eth. An empty extension list expects zero events.
    function _checkExtensions(
        Rig memory r,
        LaunchV2Lib.Launch memory l,
        Vm.Log[] memory logs,
        address token
    ) internal view {
        uint256 total = IERC20(token).totalSupply();
        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(r.factory)) continue;
            if (logs[i].topics[0] != IArtCoinsFactoryV2.ExtensionTriggered.selector) continue;
            IArtCoinsFactoryV2.ExtensionConfigV2 memory e = l.cfg.extensions[seen];
            assertEq(address(uint160(uint256(logs[i].topics[1]))), token, "ext token");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), e.extension, "ext address");
            (uint256 supply, uint256 msgValue) = abi.decode(logs[i].data, (uint256, uint256));
            assertEq(supply, (total * e.extensionBps) / Constants.BPS, "ext supply share");
            assertEq(msgValue, e.msgValue, "ext msgValue");
            ++seen;
        }
        assertEq(seen, l.cfg.extensions.length, "ExtensionTriggered count");
    }

    // ── swaps through the live universal router ───────────────────────────

    function _urBuy(PoolKey memory key, uint256 ethIn, bytes memory hookData)
        internal
        returns (uint256 got)
    {
        address coin = Currency.unwrap(key.currency1);
        bytes memory actions = abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(FcExactIn(key, true, uint128(ethIn), 0, hookData));
        params[1] = abi.encode(key.currency0, ethIn);
        params[2] = abi.encode(key.currency1, uint256(0));
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(actions, params);
        inputs[1] = abi.encode(address(0), address(this), uint256(0));
        vm.deal(address(this), address(this).balance + ethIn);
        uint256 c0 = IERC20(coin).balanceOf(address(this));
        uint256 g = gasleft();
        IFcUniversalRouter(FC_UR).execute{value: ethIn}(
            abi.encodePacked(uint8(0x10), uint8(0x04)), inputs, block.timestamp
        );
        g -= gasleft();
        got = IERC20(coin).balanceOf(address(this)) - c0;
        console2.log("buy gas", g);
        assertGt(got, 0, "buy got nothing");
        assertEq(FC_UR.balance, 0, "universal router holds no eth");
    }

    function _urSell(PoolKey memory key, uint256 coinIn, bytes memory hookData)
        internal
        returns (uint256 got)
    {
        address coin = Currency.unwrap(key.currency1);
        IERC20(coin).approve(FC_PERMIT2, type(uint256).max);
        IFcPermit2(FC_PERMIT2)
            .approve(coin, FC_UR, type(uint160).max, uint48(block.timestamp + 1 days));
        bytes memory actions = abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(FcExactIn(key, false, uint128(coinIn), 0, hookData));
        params[1] = abi.encode(key.currency1, coinIn);
        params[2] = abi.encode(key.currency0, uint256(0));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        uint256 e0 = address(this).balance;
        uint256 g = gasleft();
        IFcUniversalRouter(FC_UR).execute(abi.encodePacked(uint8(0x10)), inputs, block.timestamp);
        g -= gasleft();
        got = address(this).balance - e0;
        console2.log("sell gas", g);
        assertGt(got, 0, "sell got nothing");
    }

    /// @dev Hook data naming `to` as the refund address.
    function _refundData(address to) internal pure returns (bytes memory) {
        return abi.encode(
            IArtCoinsHook.PoolSwapData({
                mevModuleSwapData: abi.encode(to), poolExtensionSwapData: ""
            })
        );
    }

    /// @dev Buy inside the anti sniper window, buy after it, sell a quarter. Returns coin held.
    function _flow(PoolKey memory key, address token, bytes memory hookData)
        internal
        returns (uint256 coinHeld)
    {
        _urBuy(key, 0.5 ether, hookData);
        vm.warp(block.timestamp + 5000);
        vm.roll(block.number + 400);
        _urBuy(key, 0.5 ether, hookData);
        coinHeld = IERC20(token).balanceOf(address(this));
        _urSell(key, coinHeld / 4, hookData);
    }

    // ── the sequence ──────────────────────────────────────────────────────

    /// @notice RUNBOOK 2b steps 3 to 7 in order with the bounty recipient of `l`: launch config
    ///         hash, TokenCreatedV2 fields, gas, extension effects, Universal Router legs, the
    ///         bounty paid or credited to the recipient, `processFees()`, `processBurn(minOut)`.
    function _rehearse(Rig memory r, LaunchV2Lib.Launch memory l) internal {
        address refundTo = makeAddr("rehearsal.refund");
        address bounty = l.cfg.fee.bountyRecipient;
        (address token, PoolKey memory key) = _launchChecked(r, l);
        assertEq(r.escrow.balances(refundTo, address(0)), 0, "refund address credit at launch");

        uint256 owed0 = bounty.balance + r.escrow.balances(bounty, address(0));
        uint256 held = _flow(key, token, _refundData(refundTo));
        assertGt(held, 0, "coin held");
        assertEq(r.escrow.balances(refundTo, address(0)), 0, "full fills credit no refund");
        assertEq(refundTo.balance, 0, "full fills pay no refund");
        // the bounty leg reaches the recipient by push or by escrow credit
        assertGt(
            bounty.balance + r.escrow.balances(bounty, address(0)), owed0, "bounty paid or credited"
        );

        _processFees(r);
        _processBurn(r);
    }

    /// @notice The escrow path: `l.cfg.fee.bountyRecipient` is replaced by a contract that
    ///         rejects eth, so its bounty is credited in the escrow and claimable.
    function _rehearseRejecting(Rig memory r, LaunchV2Lib.Launch memory l) internal {
        FcRejecter rej = new FcRejecter();
        l.cfg.fee.bountyRecipient = payable(address(rej));
        address refundTo = makeAddr("rehearsal.refund");

        (address token, PoolKey memory key) = _launchChecked(r, l);
        // the dev buy swap pays the baseline skim, whose bounty leg is credited at launch
        uint256 launchCredit = r.escrow.balances(address(rej), address(0));
        if (r.devBuy != address(0) && _hasExtension(l, r.devBuy)) {
            assertGt(launchCredit, 0, "dev buy skim bounty credited at launch");
        } else {
            assertEq(launchCredit, 0, "no credit before swaps");
        }

        _flow(key, token, _refundData(refundTo));
        uint256 credit = r.escrow.balances(address(rej), address(0));
        console2.log("escrow credit of the rejecting bounty recipient", credit);
        assertGt(credit, 0, "bounty credited to escrow");
        address payee = makeAddr("rehearsal.payee");
        rej.claimTo(r.escrow, payee);
        assertEq(payee.balance, credit, "claimTo paid");
        assertEq(r.escrow.balances(address(rej), address(0)), 0, "credit cleared");
    }

    function _hasExtension(LaunchV2Lib.Launch memory l, address ext) internal pure returns (bool) {
        for (uint256 i; i < l.cfg.extensions.length; ++i) {
            if (l.cfg.extensions[i].extension == ext) return true;
        }
        return false;
    }

    /// @dev Exact split of everything the controller holds or is owed. The burn leg is the
    ///      remainder after the treasury share, so rounding dust goes to the burn router.
    function _processFees(Rig memory r) internal {
        ProtocolFeeControllerV2 c = r.controller;
        address treasury = c.treasury();
        address router = c.burnRouter();
        assertEq(c.treasuryBps(), DeployV2Lib.TREASURY_BPS, "split at launch value");

        uint256 pending = c.pending();
        console2.log("controller pending", pending);
        assertGt(pending, 0, "protocol fees accrued");
        uint256 treasuryAmount = (pending * c.treasuryBps()) / Constants.BPS;
        uint256 burnAmount = pending - treasuryAmount;

        uint256 t0 = treasury.balance + r.escrow.balances(treasury, address(0));
        uint256 r0 = router.balance;
        vm.prank(makeAddr("rehearsal.keeper"));
        c.processFees();

        assertEq(
            treasury.balance + r.escrow.balances(treasury, address(0)) - t0,
            treasuryAmount,
            "treasury leg (paid or credited)"
        );
        assertEq(router.balance - r0, burnAmount, "burn leg incl. dust");
        assertEq(address(c).balance, 0, "controller drained");
        assertEq(c.pending(), 0, "nothing pending");
    }

    /// @dev `processBurn(minOut)` with the router's own floor for the current budget. The router wraps its
    ///      ETH, swaps `wethIn` WETH, burns the LAYER and pays the keeper `reward` from its WETH (reported
    ///      in `Burned`), so final WETH = initial ETH + initial WETH - wethIn - reward.
    function _processBurn(Rig memory r) internal {
        BurnRouterV2 router = r.router;
        vm.roll(block.number + 1);
        uint256 budget = router.swapBudget();
        assertGt(budget, 0, "burn budget");
        uint256 minOut = router.floorFor(budget);
        assertGt(minOut, 0, "burn floor");
        uint256 supply0 = IERC20(r.layer).totalSupply();
        uint256 eth0 = address(router).balance;
        uint256 weth0 = IERC20(FC_WETH).balanceOf(address(router));
        address keeper = makeAddr("rehearsal.keeper");
        uint256 keeper0 = keeper.balance;

        vm.recordLogs();
        vm.prank(keeper);
        (uint256 wethIn, uint256 burned) = router.processBurn(minOut);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 reward;
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(router)) continue;
            if (logs[i].topics[0] != IBurnRouterV2.Burned.selector) continue;
            ++n;
            uint256 eventWethIn;
            uint256 eventBurned;
            (eventWethIn, eventBurned, reward) =
                abi.decode(logs[i].data, (uint256, uint256, uint256));
            assertEq(eventWethIn, wethIn, "Burned wethIn");
            assertEq(eventBurned, burned, "Burned burned");
        }
        assertEq(n, 1, "one Burned");

        console2.log("burn wethIn", wethIn);
        console2.log("burn LAYER burned", burned);
        console2.log("keeper reward", reward);
        assertGe(burned, minOut, "floor enforced");
        assertLe(wethIn, budget, "spent within budget");
        assertEq(keeper.balance - keeper0, reward, "keeper paid the reward in eth");
        assertEq(IERC20(r.layer).totalSupply(), supply0 - burned, "LAYER supply reduced by burned");
        assertEq(IERC20(r.layer).balanceOf(address(router)), 0, "no LAYER left in router");
        assertEq(address(router).balance, 0, "router eth wrapped");
        assertEq(
            IERC20(FC_WETH).balanceOf(address(router)),
            eth0 + weth0 - wethIn - reward,
            "weth accounted exactly"
        );
    }
}
