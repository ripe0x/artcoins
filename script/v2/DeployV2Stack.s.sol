// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Addresses} from "../Addresses.sol";
import {DeployV2Lib} from "./DeployV2Lib.sol";

import {Script, console2} from "forge-std/Script.sol";

/// @title  DeployV2Stack
/// @notice Deploys and wires the whole v2 stack in one broadcast (DESIGN d7),
///         runs every post deploy assert, prints the registry json and writes
///         it to `tmp/v2-deploy-<chainid>.json` (input of `verify-v2.sh`).
///         No key is read: the operator signs with `--ledger`, `--account` or
///         `--private-key` on the command line. Nothing is sent without `--broadcast`.
///
///   dry run on a fork (no key):
///     FOUNDRY_PROFILE=ci forge script script/v2/DeployV2Stack.s.sol --rpc-url $MAINNET_RPC_URL --sender $OWNER
///   broadcast with a ledger:
///     FOUNDRY_PROFILE=ci forge script script/v2/DeployV2Stack.s.sol --rpc-url $MAINNET_RPC_URL \
///       --ledger --sender $OWNER --broadcast --slow
///
///   env (all optional):
///     OWNER                         default Addresses.OWNER. ownership target of every owned contract
///     TREASURY                      default OWNER. ProtocolFeeControllerV2 treasury
///     TREASURY_BPS                  default 9000 (Constants allow 4000..9000)
///     REFERRAL_PAYOUT               default 0 = the new escrow (see DeployV2Lib.Params)
///     DEPLOY_FEE                    default 0.069 ether (wei)
///     PROTOCOL_BPS                  default 2000
///     MIN_PROTOCOL_SKIM_SHARE_BPS   default 0
///   when the broadcaster is not OWNER, the escrow, hook, locker and factory
///   end with `pendingOwner == OWNER`; OWNER must call `acceptOwnership()` on
///   each (script/v2/README.md).
contract DeployV2Stack is Script {
    string internal constant OUT_DIR = "tmp";

    function params(address broadcaster) public view returns (DeployV2Lib.Params memory p) {
        address owner = vm.envOr("OWNER", Addresses.OWNER);
        p = DeployV2Lib.defaults(
            owner,
            broadcaster,
            Addresses.POOL_MANAGER,
            Addresses.POSITION_MANAGER,
            Addresses.PERMIT2,
            Addresses.CREATE2_DEPLOYER
        );
        p.treasury = vm.envOr("TREASURY", owner);
        p.treasuryBps = uint16(vm.envOr("TREASURY_BPS", uint256(DeployV2Lib.TREASURY_BPS)));
        p.referralPayout = vm.envOr("REFERRAL_PAYOUT", address(0));
        p.deployFee = vm.envOr("DEPLOY_FEE", DeployV2Lib.DEPLOY_FEE);
        p.protocolBps = uint16(vm.envOr("PROTOCOL_BPS", uint256(DeployV2Lib.PROTOCOL_BPS)));
        p.minProtocolSkimShareBps = uint16(vm.envOr("MIN_PROTOCOL_SKIM_SHARE_BPS", uint256(0)));
    }

    function run() external returns (DeployV2Lib.Stack memory s) {
        require(block.chainid == Addresses.CHAIN_ID, "DeployV2Stack: mainnet (or a mainnet fork) only");

        vm.startBroadcast();
        (, address broadcaster,) = vm.readCallers();
        DeployV2Lib.Params memory p = params(broadcaster);
        _banner(p);
        s = DeployV2Lib.deploy(p);
        vm.stopBroadcast();

        DeployV2Lib.check(s, p, false);
        console2.log("post deploy asserts: ok");

        string memory json = registryJson(s, p);
        console2.log("---- registry json (paste `contracts` into deployments/mainnet.json) ----");
        console2.log(json);
        string memory path = string.concat(OUT_DIR, "/v2-deploy-", vm.toString(block.chainid), ".json");
        vm.createDir(OUT_DIR, true);
        vm.writeFile(path, json);
        console2.log("written:", path);
        if (p.owner != p.broadcaster) {
            console2.log("OWNER must acceptOwnership() on escrow, hook, locker, factory");
        }
    }

    function _banner(DeployV2Lib.Params memory p) internal view {
        console2.log("== artcoins v2 stack deploy ==");
        console2.log("chainid     ", block.chainid);
        console2.log("block       ", block.number);
        console2.log("broadcaster ", p.broadcaster);
        console2.log("owner       ", p.owner);
        console2.log("treasury    ", p.treasury);
        console2.log("treasuryBps ", p.treasuryBps);
        console2.log("referral    ", p.referralPayout);
        console2.log("deployFee   ", p.deployFee);
        console2.log("protocolBps ", p.protocolBps);
        console2.log("minSkimShare", p.minProtocolSkimShareBps);
    }

    // ── json (registry contract format, DeployV2Lib order) ───────────────────

    function registryJson(DeployV2Lib.Stack memory s, DeployV2Lib.Params memory p)
        public
        view
        returns (string memory)
    {
        address[10] memory a = DeployV2Lib.addresses(s);
        string[10] memory n = DeployV2Lib.names();
        string[10] memory src = DeployV2Lib.paths();
        string[10] memory role = DeployV2Lib.roles();
        bytes[10] memory args = DeployV2Lib.ctorArgs(s, p);

        string[10] memory key = [
            "escrow", "allowlist", "hook", "locker", "mev", "factory", "tokenDeployer",
            "burnRouter", "controller", "keeper"
        ];
        string memory contracts = "";
        string memory verify = "";
        string memory flat = "";
        for (uint256 i; i < 10; ++i) {
            string memory sep = i == 0 ? "" : ",";
            contracts = string.concat(contracts, sep, _entry(s, p, i, a[i], n[i], src[i], role[i]));
            flat = string.concat(flat, sep, '"', key[i], '":"', vm.toString(a[i]), '"');
            verify = string.concat(
                verify,
                sep,
                '{"name":"', n[i], '","address":"', vm.toString(a[i]), '","contract":"', src[i],
                ":", n[i], '","args":"', vm.toString(args[i]), '"}'
            );
        }
        return string.concat(
            '{"chainId":', vm.toString(block.chainid),
            ',"simulatedAtBlock":', vm.toString(block.number),
            ',"broadcaster":"', vm.toString(p.broadcaster),
            '","owner":"', vm.toString(p.owner),
            '","ownershipPending":', p.owner == p.broadcaster ? "false" : "true",
            ',"hookSalt":"', vm.toString(s.hookSalt),
            '","stack":{"v2":{"label":"v2 stack (skim hook v2, constants bound)","status":"current","factory":"',
            vm.toString(address(s.factory)),
            '","deployedAt":null,"notes":"deployed by script/v2/DeployV2Stack.s.sol. factory ships deprecated (owner only) until the first coin ran a fee cycle"}}',
            ',"addresses":{', flat, '}',
            ',"contracts":[', contracts, '],"verify":[', verify, "]}"
        );
    }

    function _entry(
        DeployV2Lib.Stack memory s,
        DeployV2Lib.Params memory p,
        uint256 i,
        address a,
        string memory name,
        string memory src,
        string memory role
    ) internal view returns (string memory) {
        // owned: escrow 0, allowlist 1, hook 2, locker 3, factory 5, router 7, controller 8
        bool owned = i == 0 || i == 1 || i == 2 || i == 3 || i == 5 || i == 7 || i == 8;
        string memory state = i == 5 ? "deprecated" : (i == 2 || i == 4) ? "enabled" : "unknown";
        string memory note = i == 2
            ? string.concat("CREATE2 via ", vm.toString(p.create2Deployer), " salt ", vm.toString(s.hookSalt))
            : "v2 stack";
        return string.concat(
            '{"name":"', name, '","address":"', vm.toString(a),
            '","stack":"v2","role":"', role,
            '","deployBlock":null,"deployTxHash":null,"deployedAt":null,"deployer":"', vm.toString(p.broadcaster),
            '","source":{"repoPath":"', src, '","commit":null,"bytecodeMatch":"unverified"}',
            ',"etherscanVerified":"unknown","owner":', owned ? string.concat('"', vm.toString(p.owner), '"') : "null",
            ',"state":"', state, '","status":"current","provenance":"broadcast","chainVerified":false,"notes":"', note, '"}'
        );
    }
}
