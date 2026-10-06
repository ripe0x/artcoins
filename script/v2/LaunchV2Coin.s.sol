// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Constants} from "../../src/Constants.sol";
import {IArtCoinsFactoryV2} from "../../src/v2/interfaces/IArtCoinsFactoryV2.sol";
import {IArtCoinsHookV2} from "../../src/v2/interfaces/IArtCoinsHookV2.sol";
import {IArtCoinsLpLockerV2} from "../../src/v2/interfaces/IArtCoinsLpLockerV2.sol";
import {IArtCoinsMevSkimV2} from "../../src/v2/interfaces/IArtCoinsMevSkimV2.sol";
import {IArtCoinsTokenV2} from "../../src/v2/interfaces/IArtCoinsTokenV2.sol";
import {IConstantsBound} from "../../src/v2/interfaces/IConstantsBound.sol";

import {Script, console2} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

interface IOwnedFactoryV2 {
    function owner() external view returns (address);
    function tokenDeployer() external view returns (address);
}

/// @title  LaunchV2Lib
/// @notice Json launch config parsing, preflight and dry run for the v2
///         factory. Shared by `LaunchV2Coin` and the fork tests.
/// @dev    Config format: script/v2/launch-configs/example.json. No launch
///         extensions and no pool extension (add them by hand if ever needed).
library LaunchV2Lib {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    string internal constant EXAMPLE_PATH = "script/v2/launch-configs/example.json";

    struct Target {
        address factory;
        address hook;
        address locker;
        address mev;
    }

    struct Launch {
        IArtCoinsFactoryV2.DeploymentConfigV2 cfg;
        uint16 protocolBps;
        bool example;
        address expectedToken;
    }

    // ── parse ─────────────────────────────────────────────────────────────

    function parse(string memory j, Target memory t) internal pure returns (Launch memory l) {
        l.example = vm.parseJsonBool(j, ".example");
        l.protocolBps = _u16(vm.parseJsonUint(j, ".protocolBps"));
        l.expectedToken = vm.parseJsonAddress(j, ".expectedToken");

        IArtCoinsFactoryV2.DeploymentConfigV2 memory c = l.cfg;
        c.token.tokenAdmin = vm.parseJsonAddress(j, ".token.tokenAdmin");
        c.token.name = vm.parseJsonString(j, ".token.name");
        c.token.symbol = vm.parseJsonString(j, ".token.symbol");
        c.token.salt = vm.parseJsonBytes32(j, ".token.salt");
        c.token.image = vm.parseJsonString(j, ".token.image");
        c.token.metadata = vm.parseJsonString(j, ".token.metadata");
        c.token.context = vm.parseJsonString(j, ".token.context");
        c.token.totalSupply = vm.parseJsonUint(j, ".token.totalSupply");
        c.token.renderer = vm.parseJsonAddress(j, ".token.renderer");

        c.pool.hook = t.hook;
        c.pool.tickIfToken0IsArtCoin = _i24(vm.parseJsonInt(j, ".pool.tickIfToken0IsArtCoin"));
        c.pool.tickSpacing = _i24(vm.parseJsonInt(j, ".pool.tickSpacing"));

        c.fee.lpFee = _u24(vm.parseJsonUint(j, ".fee.lpFee"));
        c.fee.baselineSkimBps = _u24(vm.parseJsonUint(j, ".fee.baselineSkimBps"));
        c.fee.bountyBps = _u16(vm.parseJsonUint(j, ".fee.bountyBps"));
        c.fee.maxReferralBpsOfVolume = _u24(vm.parseJsonUint(j, ".fee.maxReferralBpsOfVolume"));
        c.fee.bountyRecipient = payable(vm.parseJsonAddress(j, ".fee.bountyRecipient"));

        c.locker.locker = t.locker;
        c.locker.rewardRecipients = vm.parseJsonAddressArray(j, ".locker.rewardRecipients");
        c.locker.rewardBps = _u16s(vm.parseJsonUintArray(j, ".locker.rewardBps"));
        c.locker.tickLower = _i24s(vm.parseJsonIntArray(j, ".locker.tickLower"));
        c.locker.tickUpper = _i24s(vm.parseJsonIntArray(j, ".locker.tickUpper"));
        c.locker.positionBps = _u16s(vm.parseJsonUintArray(j, ".locker.positionBps"));

        c.mev.module = t.mev;
        c.mev.startingSkimBps = _u24(vm.parseJsonUint(j, ".mev.startingSkimBps"));
        c.mev.windowSeconds = _u32(vm.parseJsonUint(j, ".mev.windowSeconds"));

        c.tax.mode = _u8(vm.parseJsonUint(j, ".tax.mode"));
        c.tax.taxBps = _u16(vm.parseJsonUint(j, ".tax.taxBps"));
        c.tax.taxBpsMax = _u16(vm.parseJsonUint(j, ".tax.taxBpsMax"));
        c.tax.taxSink = vm.parseJsonAddress(j, ".tax.taxSink");
        c.tax.venueAdmin = vm.parseJsonAddress(j, ".tax.venueAdmin");
        c.tax.exempt = _addrs(j, ".tax.exempt");
        // venues: none at launch (add only later by the venue admin)
    }

    // ── preflight ─────────────────────────────────────────────────────────

    /// @notice Fails closed on any wiring gap. Returns the predicted token
    ///         for `owner` and the exact msg.value.
    function preflight(Target memory t, Launch memory l, address owner)
        internal
        view
        returns (address predicted, uint256 value)
    {
        IArtCoinsFactoryV2 f = IArtCoinsFactoryV2(t.factory);
        require(t.factory.code.length != 0, "preflight: factory has no code");
        bytes32 h = Constants.hash();
        require(f.constantsHash() == h, "preflight: factory constantsHash");
        require(IConstantsBound(t.hook).constantsHash() == h, "preflight: hook constantsHash");
        require(IConstantsBound(t.locker).constantsHash() == h, "preflight: locker constantsHash");
        require(IConstantsBound(t.mev).constantsHash() == h, "preflight: mev constantsHash");
        require(IOwnedFactoryV2(t.factory).owner() == owner, "preflight: owner is not factory owner");
        require(IOwnedFactoryV2(t.factory).tokenDeployer() != address(0), "preflight: no token deployer");
        require(f.enabledHooks(t.hook), "preflight: hook not enabled");
        require(f.enabledLockers(t.locker), "preflight: locker not enabled");
        require(f.enabledMevModules(t.mev), "preflight: mev module not enabled");
        require(IArtCoinsHookV2(t.hook).isLauncher(t.factory), "preflight: factory not hook launcher");
        require(IArtCoinsLpLockerV2(t.locker).isLauncher(t.factory), "preflight: factory not locker launcher");
        require(IArtCoinsMevSkimV2(t.mev).hook() == t.hook, "preflight: mev module bound to another hook");
        require(f.protocolRecipient() != address(0), "preflight: protocol recipient unset");
        require(f.referralPayout().code.length != 0, "preflight: referral payout has no code");
        value = f.deployFee();
        require(value == 0 || f.teamFeeRecipient() != address(0), "preflight: team fee recipient unset");
        require(
            l.protocolBps <= Constants.MAX_PROTOCOL_FEE_BPS, "preflight: protocolBps above max"
        );

        predicted = f.predictToken(owner, l.cfg);
        require(predicted.code.length == 0, "preflight: predicted token already deployed");
        require(
            l.expectedToken == address(0) || l.expectedToken == predicted,
            "preflight: expectedToken differs from predictToken"
        );
        if (l.cfg.fee.bountyRecipient.code.length == 0) {
            console2.log("WARN bounty recipient has no code (a treasury contract is expected)");
        }
    }

    // ── dry run ───────────────────────────────────────────────────────────

    /// @notice eth_call style: launches as `owner` under a state snapshot,
    ///         checks the result, then reverts to the snapshot.
    function dryRun(Target memory t, Launch memory l, address owner, uint256 value)
        internal
        returns (address token, PoolId poolId)
    {
        uint256 snap = vm.snapshotState();
        vm.deal(owner, owner.balance + value);
        vm.deal(address(this), address(this).balance + value);
        vm.prank(owner);
        token = IArtCoinsFactoryV2(t.factory).deployTokenAsOwner{value: value}(l.cfg, l.protocolBps);
        poolId = checkLaunched(t, l, token);
        vm.revertToState(snap);
    }

    /// @notice Post launch asserts (dry run and live).
    function checkLaunched(Target memory t, Launch memory l, address token)
        internal
        view
        returns (PoolId poolId)
    {
        IArtCoinsFactoryV2 f = IArtCoinsFactoryV2(t.factory);
        require(f.isArtCoin(token), "launch: not an art coin");
        IArtCoinsFactoryV2.DeploymentInfoV2 memory info = f.deploymentInfo(token);
        poolId = info.poolId;
        require(info.hook == t.hook && info.locker == t.locker && info.mevModule == t.mev, "launch: info");
        require(info.version == Constants.STACK_VERSION, "launch: info version");
        IArtCoinsHookV2.PoolInfo memory pi = IArtCoinsHookV2(t.hook).poolInfo(poolId);
        require(pi.version == Constants.STACK_VERSION && pi.token == token, "launch: hook poolInfo");
        require(pi.taxMode == l.cfg.tax.mode, "launch: tax mode");
        IArtCoinsTokenV2 c = IArtCoinsTokenV2(token);
        require(c.launcherVersion() == Constants.STACK_VERSION, "launch: token version");
        require(c.canonicalPoolId() == PoolId.unwrap(poolId), "launch: canonical pool");
        require(
            IArtCoinsLpLockerV2(t.locker).tokenRewards(token).numPositions
                == l.cfg.locker.tickLower.length,
            "launch: locker positions"
        );
    }

    // ── casts (fail on overflow) ──────────────────────────────────────────

    function _u8(uint256 v) private pure returns (uint8) {
        require(v <= type(uint8).max, "json: uint8");
        return uint8(v);
    }

    function _u16(uint256 v) private pure returns (uint16) {
        require(v <= type(uint16).max, "json: uint16");
        return uint16(v);
    }

    function _u24(uint256 v) private pure returns (uint24) {
        require(v <= type(uint24).max, "json: uint24");
        return uint24(v);
    }

    function _u32(uint256 v) private pure returns (uint32) {
        require(v <= type(uint32).max, "json: uint32");
        return uint32(v);
    }

    function _i24(int256 v) private pure returns (int24) {
        require(v >= type(int24).min && v <= type(int24).max, "json: int24");
        return int24(v);
    }

    function _u16s(uint256[] memory v) private pure returns (uint16[] memory o) {
        o = new uint16[](v.length);
        for (uint256 i; i < v.length; ++i) {
            o[i] = _u16(v[i]);
        }
    }

    function _i24s(int256[] memory v) private pure returns (int24[] memory o) {
        o = new int24[](v.length);
        for (uint256 i; i < v.length; ++i) {
            o[i] = _i24(v[i]);
        }
    }

    /// @dev `[]` parses as empty bytes in some forge versions; treat as empty.
    function _addrs(string memory j, string memory key) private pure returns (address[] memory) {
        bytes memory raw = vm.parseJson(j, key);
        if (raw.length <= 64) return new address[](0);
        return vm.parseJsonAddressArray(j, key);
    }
}

/// @title  LaunchV2Coin
/// @notice Launches one coin through `deployTokenAsOwner` from a json config.
///         Preflight (wiring, `predictToken`), then an eth_call style dry run
///         under a snapshot, then the real tx inside `vm.startBroadcast()`.
///         Nothing is sent without `--broadcast`; the signer must be the factory owner.
///
///   stack addresses: env FACTORY_V2, HOOK_V2, LOCKER_V2, MEV_V2, else
///   `.addresses` of tmp/v2-deploy-<chainid>.json (written by DeployV2Stack).
///
///   config: env LAUNCH_CONFIG_JSON (the json text), else the file at
///   LAUNCH_CONFIG (default script/v2/launch-configs/example.json). Reading a
///   file under script/v2 needs `{ access = "read", path = "script/v2/launch-configs" }`
///   in foundry.toml fs_permissions; LAUNCH_CONFIG_JSON or `run(string)` work without it:
///     forge script script/v2/LaunchV2Coin.s.sol --sig "run(string)" "$(cat my-coin.json)" \
///       --rpc-url $MAINNET_RPC_URL --sender $OWNER                      (dry run)
///     ... --ledger --broadcast                                            (live)
///   a config with `"example": true` is refused for broadcast unless ALLOW_EXAMPLE=true.
contract LaunchV2Coin is Script {
    function run() external {
        string memory json = vm.envOr("LAUNCH_CONFIG_JSON", string(""));
        if (bytes(json).length == 0) {
            json = vm.readFile(vm.envOr("LAUNCH_CONFIG", string(LaunchV2Lib.EXAMPLE_PATH)));
        }
        _run(json);
    }

    function run(string calldata json) external {
        _run(json);
    }

    function target() public view returns (LaunchV2Lib.Target memory t) {
        string memory deployed = "";
        string memory path = string.concat("tmp/v2-deploy-", vm.toString(block.chainid), ".json");
        try vm.readFile(path) returns (string memory j) {
            deployed = j;
        } catch {}
        t.factory = _addr("FACTORY_V2", deployed, ".addresses.factory");
        t.hook = _addr("HOOK_V2", deployed, ".addresses.hook");
        t.locker = _addr("LOCKER_V2", deployed, ".addresses.locker");
        t.mev = _addr("MEV_V2", deployed, ".addresses.mev");
    }

    function _addr(string memory env, string memory deployed, string memory key)
        internal
        view
        returns (address a)
    {
        a = vm.envOr(env, address(0));
        if (a == address(0) && bytes(deployed).length != 0) a = vm.parseJsonAddress(deployed, key);
        require(a != address(0), string.concat("LaunchV2Coin: set ", env));
    }

    function _run(string memory json) internal {
        require(block.chainid == 1, "LaunchV2Coin: mainnet (or a mainnet fork) only");
        LaunchV2Lib.Target memory t = target();
        LaunchV2Lib.Launch memory l = LaunchV2Lib.parse(json, t);
        address owner = IOwnedFactoryV2(t.factory).owner();

        (address predicted, uint256 value) = LaunchV2Lib.preflight(t, l, owner);
        console2.log("factory      ", t.factory);
        console2.log("deprecated   ", IArtCoinsFactoryV2(t.factory).deprecated());
        console2.log("owner        ", owner);
        console2.log("predicted    ", predicted);
        console2.log("msg.value    ", value);
        console2.log("protocolBps  ", l.protocolBps);
        console2.log("configHash   ", vm.toString(IArtCoinsFactoryV2(t.factory).configHash(l.cfg)));

        (address dryToken, PoolId dryPool) = LaunchV2Lib.dryRun(t, l, owner, value);
        require(dryToken == predicted, "dry run: token differs from predictToken");
        console2.log("dry run ok, pool id", vm.toString(PoolId.unwrap(dryPool)));

        vm.startBroadcast();
        (, address sender,) = vm.readCallers();
        if (sender != owner) {
            vm.stopBroadcast();
            console2.log("signer is not the factory owner: dry run only. pass --sender", owner);
            return;
        }
        require(!l.example || vm.envOr("ALLOW_EXAMPLE", false), "example config: set example=false");
        address token =
            IArtCoinsFactoryV2(t.factory).deployTokenAsOwner{value: value}(l.cfg, l.protocolBps);
        vm.stopBroadcast();

        require(token == predicted, "launch: token differs from predictToken");
        PoolId pid = LaunchV2Lib.checkLaunched(t, l, token);
        console2.log("token        ", token);
        console2.log("pool id      ", vm.toString(PoolId.unwrap(pid)));
        console2.log("next: BurnRouterV2.initialize(token, key) if the coin uses the burn leg");
    }
}
