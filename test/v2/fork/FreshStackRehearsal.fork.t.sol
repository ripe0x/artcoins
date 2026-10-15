// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Addresses} from "../../../script/Addresses.sol";
import {DeployV2Lib} from "../../../script/v2/DeployV2Lib.sol";
import {LaunchV2Lib} from "../../../script/v2/LaunchV2Coin.s.sol";
import {ForkBase} from "../harness/ForkBase.sol";
import {ForkStack} from "../harness/ForkStack.sol";
import {RehearsalFlow} from "./RehearsalFlow.sol";

/// @notice The gate 7 sequence of `FirstCoinRehearsal` against a stack deployed fresh on the
///         fork by `DeployV2Lib`, with the example launch config.
contract FreshStackRehearsalForkTest is ForkStack, RehearsalFlow {
    // both bases declare a payable receive
    receive() external payable override(ForkBase, RehearsalFlow) {}

    function setUp() public {
        forkMainnet();
    }

    function _freshRig() internal returns (Rig memory r) {
        DeployV2Lib.Params memory p = v2DefaultParams(LIVE_OWNER, LIVE_OWNER);
        DeployV2Lib.Stack memory s = deployV2Stack(p);
        r = Rig({
            factory: s.factory,
            hook: address(s.hook),
            locker: address(s.locker),
            mev: address(s.mev),
            escrow: s.escrow,
            controller: s.controller,
            router: s.burnRouter,
            layer: Addresses.COIN_LAYER,
            launcher: LIVE_OWNER,
            devBuy: address(s.devBuy),
            airdrop: address(s.airdrop),
            vault: address(s.vault)
        });
    }

    function _freshLaunch(Rig memory r) internal returns (LaunchV2Lib.Launch memory l) {
        l = LaunchV2Lib.parse(vm.readFile(LaunchV2Lib.EXAMPLE_PATH), _target(r));
        // dev buy, airdrop and vault on the fresh stack, asserted inside the launch
        _addExtensions(r, l);
    }

    function test_gate7_freshStack_fullSequence() public onlyFork {
        Rig memory r = _freshRig();
        _rehearse(r, _freshLaunch(r));
    }

    function test_gate7_freshStack_rejectingBountyRecipient() public onlyFork {
        Rig memory r = _freshRig();
        _rehearseRejecting(r, _freshLaunch(r));
    }
}
