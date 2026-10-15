// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {Addresses} from "../../../script/Addresses.sol";
import {LaunchV2Lib} from "../../../script/v2/LaunchV2Coin.s.sol";
import {IArtCoinsFactoryV2} from "../../../src/v2/interfaces/IArtCoinsFactoryV2.sol";
import {IArtCoinsFeeEscrowV2} from "../../../src/v2/interfaces/IArtCoinsFeeEscrowV2.sol";
import {IArtCoinsHookV2} from "../../../src/v2/interfaces/IArtCoinsHookV2.sol";
import {IArtCoinsLpLockerV2} from "../../../src/v2/interfaces/IArtCoinsLpLockerV2.sol";
import {BurnRouterV2} from "../../../src/v2/protocol-fee/BurnRouterV2.sol";
import {ProtocolFeeControllerV2} from "../../../src/v2/protocol-fee/ProtocolFeeControllerV2.sol";
import {FcRejecter, FcTreasury, RehearsalFlow} from "./RehearsalFlow.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Rehearsal of RUNBOOK 2b steps 3 to 6 against the deployed v2 stack.
///         Env: MAINNET_RPC_URL (default tenderly public), FORK_BLOCK (default
///         latest at or after the deploy block; must be >= 26_157_260).
contract FirstCoinRehearsal is RehearsalFlow {
    using PoolIdLibrary for PoolKey;

    address internal constant OWNER = 0xCB43078C32423F5348Cab5885911C3B5faE217F9;

    bool internal onFork;
    IArtCoinsFactoryV2 internal factory = IArtCoinsFactoryV2(Addresses.V2_FACTORY);
    IArtCoinsFeeEscrowV2 internal escrow = IArtCoinsFeeEscrowV2(Addresses.V2_ESCROW);
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        string memory rpc =
            vm.envOr("MAINNET_RPC_URL", string("https://gateway.tenderly.co/public/mainnet"));
        uint256 blk = vm.envOr("FORK_BLOCK", uint256(0));
        try vm.createSelectFork(rpc) returns (uint256) {
            if (blk != 0) vm.rollFork(blk);
            onFork = Addresses.V2_FACTORY.code.length != 0;
        } catch {
            console2.log("fork unavailable");
        }
        if (!onFork) vm.skip(true);
    }

    function _target() internal pure returns (LaunchV2Lib.Target memory t) {
        t = LaunchV2Lib.Target(
            Addresses.V2_FACTORY, Addresses.V2_HOOK, Addresses.V2_LOCKER, Addresses.V2_MEV_MODULE
        );
    }

    // ── step 3 to 5: launch ───────────────────────────────────────────────

    function _launch(string memory path, address recipient)
        internal
        returns (address token, PoolKey memory key, LaunchV2Lib.Launch memory l)
    {
        LaunchV2Lib.Target memory t = _target();
        l = LaunchV2Lib.parse(vm.readFile(path), t);
        l.cfg.fee.bountyRecipient = payable(recipient);

        (address predicted, uint256 value) = LaunchV2Lib.preflight(t, l, OWNER);
        bytes32 cfgHash = factory.configHash(l.cfg);
        vm.deal(OWNER, OWNER.balance + value);

        vm.recordLogs();
        vm.prank(OWNER);
        uint256 g = gasleft();
        token = factory.deployToken{value: value}(l.cfg);
        g -= gasleft();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        console2.log("launch gas", g);
        console2.log("launch gas headroom to 16.7M cap", FC_TX_CAP > g ? FC_TX_CAP - g : 0);
        assertLt(g, FC_TX_CAP, "launch gas above tx cap");
        assertEq(token, predicted, "token != predicted");
        PoolId pid = LaunchV2Lib.checkLaunched(t, l, token);
        assertTrue(factory.isCoin(token), "isCoin");
        assertEq(IArtCoinsHookV2(Addresses.V2_HOOK).poolInfo(pid).version, 2, "hook version");
        assertTrue(_logHas(logs, cfgHash), "configHash not echoed in TokenCreatedV2");
        key = IArtCoinsLpLockerV2(Addresses.V2_LOCKER).lockedLiquidity(token).poolKey;
        assertEq(PoolId.unwrap(key.toId()), PoolId.unwrap(pid), "pool id");
    }

    function _logHas(Vm.Log[] memory logs, bytes32 needle) internal view returns (bool) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != Addresses.V2_FACTORY) continue;
            for (uint256 j; j < logs[i].topics.length; ++j) {
                if (logs[i].topics[j] == needle) return true;
            }
            for (uint256 k; k + 32 <= logs[i].data.length; k += 32) {
                bytes32 w;
                bytes memory d = logs[i].data;
                assembly { w := mload(add(add(d, 32), k)) }
                if (w == needle) return true;
            }
        }
        return false;
    }

    // ── tests ─────────────────────────────────────────────────────────────

    function test_credits_plainTreasury() public {
        address treasury = address(new FcTreasury());
        (address token, PoolKey memory key,) =
            _launch("script/v2/launch-configs/example.json", treasury);
        assertFalse(_restricted(token), "not restricted");
        uint256 t0 = treasury.balance;
        _flow(key, token, "");
        uint256 t1 = treasury.balance;
        console2.log("treasury eth after swaps (bounty pushes)", t1 - t0);
        assertGt(t1, t0, "bounty pushed");
        console2.log("escrow credit treasury", escrow.balances(treasury, address(0)));
        // plain erc20 transfer works
        IERC20(token).transfer(alice, 1e18);
        vm.prank(alice);
        IERC20(token).transfer(bob, 1e18);
    }

    function test_credits_rejectingRecipient_escrowAndClaim() public {
        FcRejecter rej = new FcRejecter();
        (address token, PoolKey memory key,) =
            _launch("script/v2/launch-configs/example.json", address(rej));
        _flow(key, token, "");
        uint256 credit1 = escrow.balances(address(rej), address(0));
        console2.log("escrow credit after swaps", credit1);
        assertGt(credit1, 0, "bounty credited to escrow");
        address payee = makeAddr("payee");
        rej.claimTo(escrow, payee);
        assertEq(payee.balance, credit1, "claimTo paid");
        assertEq(escrow.balances(address(rej), address(0)), 0, "credit cleared");
    }

    /// @notice RUNBOOK gate 7 in full against the deployed stack: launch config hash and event,
    ///         gas, extensions, Universal Router legs with a refund address, escrow claim,
    ///         `processFees()` split, `processBurn(minOut)`.
    function test_gate7_fullSequence() public {
        Rig memory r = Rig({
            factory: factory,
            hook: Addresses.V2_HOOK,
            locker: Addresses.V2_LOCKER,
            mev: Addresses.V2_MEV_MODULE,
            escrow: escrow,
            controller: ProtocolFeeControllerV2(payable(Addresses.V2_PROTOCOL_FEE_CONTROLLER)),
            router: BurnRouterV2(payable(Addresses.V2_BURN_ROUTER)),
            layer: Addresses.COIN_LAYER,
            launcher: OWNER
        });
        LaunchV2Lib.Launch memory l =
            LaunchV2Lib.parse(vm.readFile("script/v2/launch-configs/example.json"), _target());
        _rehearse(r, l);
    }

    function test_restricted() public {
        address treasury = address(new FcTreasury());
        (address token, PoolKey memory key,) =
            _launch("script/v2/launch-configs/example-restricted.json", treasury);
        assertTrue(_restricted(token), "restricted");
        uint256 held = _flow(key, token, "");
        assertGt(held, 0);
        // wallet to wallet transfer between two EOAs reverts
        vm.prank(address(this));
        vm.expectRevert();
        IERC20(token).transfer(alice, 1e18);
    }

    function _restricted(address token) internal view returns (bool) {
        (bool ok, bytes memory r) = token.staticcall(abi.encodeWithSignature("restricted()"));
        require(ok, "restricted()");
        return abi.decode(r, (bool));
    }
}
