// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// s1 deploy suite. forks mainnet at the harness pin and runs the exact deploy
// routine of script/v2/DeployV2Stack.s.sol (script/v2/DeployV2Lib.sol) with a
// broadcaster that is not the owner, so the two step ownership hand over is
// exercised. skips cleanly when the rpc is unreachable.

import {DeployV2Lib} from "../../script/v2/DeployV2Lib.sol";
import {LaunchV2Coin, LaunchV2Lib} from "../../script/v2/LaunchV2Coin.s.sol";
import {Constants} from "../../src/Constants.sol";
import {ArtCoinsFeeEscrowV2} from "../../src/v2/ArtCoinsFeeEscrowV2.sol";
import {FeeAutoSwapperV2} from "../../src/v2/FeeAutoSwapperV2.sol";
import {ArtCoinsHookV2} from "../../src/v2/hooks/ArtCoinsHookV2.sol";
import {IArtCoinsFactoryV2} from "../../src/v2/interfaces/IArtCoinsFactoryV2.sol";
import {ForkStack} from "./harness/ForkStack.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @dev credits engine treasury stand in: empty payable receive, no other code.
contract S1Treasury {
    receive() external payable {}
}

contract DeployV2StackForkTest is ForkStack {
    /// @dev Copy of script/v2/launch-configs/example.json, used only when the
    ///      file cannot be read (foundry.toml fs_permissions has no read entry
    ///      for script/v2/launch-configs). When it can, the file wins and must
    ///      equal this copy (test_launchConfig_embeddedCopyMatchesFile).
    string internal constant EXAMPLE_JSON = '{"example":true,"about":"credits engine style coin: treasury contract as bounty recipient,'
        " tax sink and only project reward slot. VENUE tax mode at 0 bps (rate tunable by the token admin up to taxBpsMax). native eth pool,"
        ' 69 minute linear anti sniper skim from 68.69% down to the 6% baseline. replace every treasury placeholder (0x7ea5...0001) with the real treasury contract and set example to false before a broadcast.",'
        '"protocolBps":2000,"expectedToken":"0x0000000000000000000000000000000000000000","token":{"tokenAdmin":"0xCB43078C32423F5348Cab5885911C3B5faE217F9",'
        '"name":"Credits Example","symbol":"CREDX","salt":"0x0000000000000000000000000000000000000000000000000000000000000001",'
        '"image":"ipfs://example","description":"{\\"description\\":\\"credits engine example coin\\"}",'
        '"totalSupply":0,"renderer":"0x0000000000000000000000000000000000000000"},'
        '"pool":{"tickIfToken0IsCoin":-200000,"tickSpacing":200},"fee":{"lpFee":5000,"baselineSkimBps":6000,'
        '"bountyBps":8333,"maxReferralBpsOfVolume":250,"bountyRecipient":"0x7ea5000000000000000000000000000000000001"},'
        '"locker":{"rewardRecipients":["0x7ea5000000000000000000000000000000000001"],"rewardBps":[8000],'
        '"tickLower":[-200000,-160000,-120000],"tickUpper":[-120000,-100000,-60000],"positionBps":[5000,'
        '3000,2000]},"mev":{"startingSkimBps":68690,"windowSeconds":4140},'
        '"restriction":{"restricted":false,"allowed":[]}}';

    DeployV2Lib.Stack internal s;
    DeployV2Lib.Params internal p;
    address internal broadcaster = makeAddr("s1.broadcaster");
    address internal stranger = makeAddr("s1.stranger");
    address internal keeperCaller = makeAddr("s1.keeperCaller");
    S1Treasury internal treasury;

    function setUp() public {
        forkMainnet();
        if (!onFork) return;
        require(
            broadcaster.code.length == 0 && stranger.code.length == 0
                && keeperCaller.code.length == 0,
            "actor has code"
        );
        p = v2DefaultParams(LIVE_OWNER, broadcaster);
        s = deployV2Stack(p);
        treasury = new S1Treasury();
        vm.label(address(treasury), "s1Treasury");
    }

    // ══════════════════════════════════════════════════════════════════════
    // d7: wiring
    // ══════════════════════════════════════════════════════════════════════

    function test_deployV2Stack_wiringComplete() public onlyFork {
        // every step 12 assert, pending ownership state
        DeployV2Lib.check(s, p, false);

        // the routine's own asserts, spelled out
        assertEq(uint160(address(s.hook)) & 0x3FFF, 0x28CC, "hook flags");
        assertTrue(s.escrow.isCoreDepositor(address(s.hook)), "hook core depositor");
        assertTrue(s.escrow.isCoreDepositor(address(s.locker)), "locker core depositor");
        assertTrue(s.escrow.isDepositor(address(s.controller)), "controller depositor");
        assertFalse(s.escrow.isCoreDepositor(address(s.controller)), "controller not core");
        assertTrue(s.hook.isLauncher(address(s.factory)), "hook launcher");
        assertTrue(s.locker.isLauncher(address(s.factory)), "locker launcher");
        assertEq(s.locker.keeperRewardBps(), 0, "D28 keeper reward");
        assertTrue(s.factory.deprecated(), "ships deprecated");
        assertEq(s.factory.tokenDeployer(), address(s.tokenDeployer), "D38 deployer");
        assertEq(s.factory.deployFee(), 0.069 ether, "deploy fee");
        assertEq(s.factory.defaultProtocolFeeBps(), 2000, "protocol bps");
        assertEq(s.factory.minProtocolSkimShareBps(), 1000, "D52 protocol skim floor");
        assertEq(s.factory.protocolRecipient(), address(s.controller), "protocol recipient");
        assertEq(s.factory.teamFeeRecipient(), LIVE_OWNER, "team fee recipient");
        assertEq(s.controller.treasury(), LIVE_OWNER, "treasury = owner");
        assertEq(s.burnRouter.coin(), address(0), "router not initialized");

        // two step hand over: the broadcaster keeps power until OWNER accepts
        Ownable2Step[4] memory o = DeployV2Lib.pendingOwnables(s);
        for (uint256 i; i < 4; ++i) {
            assertEq(o[i].owner(), broadcaster, "owner before accept");
            assertEq(o[i].pendingOwner(), LIVE_OWNER, "pending owner");
            vm.prank(stranger);
            vm.expectRevert(
                abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger)
            );
            o[i].acceptOwnership();
        }
        acceptV2Ownership(s, p);
        DeployV2Lib.check(s, p, true);
        vm.prank(broadcaster);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, broadcaster)
        );
        s.factory.setDeprecated(false);

        // D36: the hook refuses an escrow that does not list it as core depositor
        ArtCoinsFeeEscrowV2 other = new ArtCoinsFeeEscrowV2(LIVE_OWNER);
        vm.prank(LIVE_OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(ArtCoinsHookV2.EscrowNotCoreDepositor.selector, address(other))
        );
        s.hook.setFeeEscrow(address(other));

        // closed to the public
        vm.deal(stranger, 1 ether);
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c = _launch(address(treasury)).cfg;
        vm.prank(stranger);
        vm.expectRevert(IArtCoinsFactoryV2.Deprecated.selector);
        s.factory.deployToken{value: 0.069 ether}(c);
    }

    // ══════════════════════════════════════════════════════════════════════
    // d7: provenance
    // ══════════════════════════════════════════════════════════════════════

    function test_deployV2Stack_runtimeMatchesBuild() public onlyFork {
        address[10] memory a = DeployV2Lib.addresses(s);
        string[10] memory n = DeployV2Lib.names();
        string[10] memory src = DeployV2Lib.paths();
        // every immutable in the stack is one of these addresses
        bytes32[] memory imm = new bytes32[](13);
        imm[0] = bytes32(uint256(uint160(POOL_MANAGER)));
        imm[1] = bytes32(uint256(uint160(POSITION_MANAGER)));
        imm[2] = bytes32(uint256(uint160(PERMIT2)));
        for (uint256 i; i < 10; ++i) {
            imm[3 + i] = bytes32(uint256(uint160(a[i])));
        }
        for (uint256 i; i < 10; ++i) {
            bytes memory art = vm.getDeployedCode(string.concat(src[i], ":", n[i]));
            bytes memory chain = a[i].code;
            assertGt(art.length, 0, n[i]);
            assertEq(chain.length, art.length, string.concat(n[i], ": length"));
            (bytes memory masked, uint256 slots) = _maskImmutables(chain, art, imm);
            assertEq(keccak256(masked), keccak256(art), string.concat(n[i], ": runtime"));
            // every contract but the escrow and the allowlist has address immutables
            if (i == 2 || i == 3 || i == 4 || i == 5 || i == 6 || i == 7 || i == 8 || i == 9) {
                assertGt(slots, 0, string.concat(n[i], ": immutables found"));
            }
        }
    }

    /// @dev Zeroes every 32 byte word of `chain` that is all zero in `art`
    ///      (an immutable slot in a forge artifact) and holds one of `values`.
    function _maskImmutables(bytes memory chain, bytes memory art, bytes32[] memory values)
        internal
        pure
        returns (bytes memory out, uint256 slots)
    {
        out = bytes.concat(chain);
        uint256 len = out.length;
        if (len < 32) return (out, 0);
        for (uint256 i; i <= len - 32; ++i) {
            bytes32 wa;
            bytes32 wc;
            assembly ("memory-safe") {
                wa := mload(add(add(art, 0x20), i))
                wc := mload(add(add(out, 0x20), i))
            }
            if (wa != 0 || wc == 0) continue;
            for (uint256 k; k < values.length; ++k) {
                if (wc == values[k]) {
                    assembly ("memory-safe") {
                        mstore(add(add(out, 0x20), i), 0)
                    }
                    ++slots;
                    i += 31;
                    break;
                }
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    // runbook 2b, 2c: owner launch while deprecated, then open
    // ══════════════════════════════════════════════════════════════════════

    function test_deployV2Stack_launchFirstCoinAsOwner_thenOpen() public onlyFork {
        acceptV2Ownership(s, p);
        LaunchV2Lib.Target memory t = _target();
        LaunchV2Lib.Launch memory l = _launch(address(treasury));
        assertTrue(l.example, "example flag");
        assertFalse(l.cfg.restriction.restricted, "example coin not restricted");
        assertEq(l.cfg.mev.windowSeconds, 69 minutes, "69 minute skim");

        (address predicted, uint256 value) = LaunchV2Lib.preflight(t, l, LIVE_OWNER);
        assertEq(value, 0.069 ether, "value");
        (address dry,) = LaunchV2Lib.dryRun(t, l, LIVE_OWNER, value);
        assertEq(dry, predicted, "dry run address");
        assertEq(dry.code.length, 0, "dry run reverted to snapshot");
        assertFalse(s.factory.isCoin(dry), "dry run left no record");

        // a stranger cannot launch while deprecated
        vm.deal(stranger, 10 ether);
        vm.prank(stranger);
        vm.expectRevert(IArtCoinsFactoryV2.Deprecated.selector);
        s.factory.deployToken{value: value}(l.cfg);

        // owner launch, the credits engine coin
        vm.deal(LIVE_OWNER, LIVE_OWNER.balance + value);
        vm.prank(LIVE_OWNER);
        address coin1 = s.factory.deployTokenAsOwner{value: value}(l.cfg, l.protocolBps);
        assertEq(coin1, predicted, "owner coin at predicted address");
        LaunchV2Lib.checkLaunched(t, l, coin1);
        assertEq(s.locker.rewardRecipients(coin1).length, 2, "project slot + protocol slot");

        // open, last
        vm.prank(LIVE_OWNER);
        s.factory.setDeprecated(false);
        uint256 teamBefore = LIVE_OWNER.balance;
        vm.prank(stranger);
        address coin2 = s.factory.deployToken{value: value}(l.cfg);
        assertTrue(coin2 != coin1, "other sender, other address");
        assertEq(coin2, s.factory.predictToken(stranger, l.cfg), "stranger predicted");
        LaunchV2Lib.checkLaunched(t, l, coin2);
        assertEq(LIVE_OWNER.balance - teamBefore, value, "deploy fee to team recipient");

        _buyThenSell(coin1);
        _buyThenSell(coin2);
    }

    // ══════════════════════════════════════════════════════════════════════
    // runbook 2b step 4: collect and forward through the keeper
    // ══════════════════════════════════════════════════════════════════════

    /// @dev The one place that touches `FeeAutoSwapperV2.Config`. Fields are assigned by name onto a
    ///      zeroed memory struct, so a field added to the struct later does not stop this file from
    ///      compiling (a removed or renamed one still does, on purpose). Everything the keeper test
    ///      relies on is then read back through the swapper's getters, so a layout change that moved
    ///      a value fails here with a clear message instead of deep inside the keeper flow.
    function _deployTreasurySwapper() internal returns (FeeAutoSwapperV2 swapper) {
        FeeAutoSwapperV2.Config memory c;
        c.owner = LIVE_OWNER;
        c.poolManager = POOL_MANAGER;
        c.feeEscrow = address(s.escrow);
        c.hook = address(s.hook);
        c.poolFee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        c.tickSpacing = 200;
        c.endRecipient = address(treasury);
        c.coin = address(0);
        c.maxSlippageBps = 500;
        c.minBlocksBetweenConverts = 1;
        c.maxStepIn = 1000 ether;
        swapper = new FeeAutoSwapperV2(c);

        assertEq(swapper.owner(), LIVE_OWNER, "swapper owner");
        assertEq(address(swapper.poolManager()), POOL_MANAGER, "swapper poolManager");
        assertEq(swapper.feeEscrow(), address(s.escrow), "swapper feeEscrow");
        assertEq(swapper.hook(), address(s.hook), "swapper hook");
        assertEq(swapper.poolFee(), LPFeeLibrary.DYNAMIC_FEE_FLAG, "swapper poolFee");
        assertEq(swapper.tickSpacing(), int24(200), "swapper tickSpacing");
        assertEq(swapper.endRecipient(), address(treasury), "swapper endRecipient");
        assertEq(swapper.coin(), address(0), "swapper artCoin unbound until setup");
        assertEq(swapper.maxSlippageBps(), 500, "swapper maxSlippageBps");
        assertEq(swapper.minBlocksBetweenConverts(), 1, "swapper minBlocksBetweenConverts");
        assertEq(swapper.maxStepIn(), 1000 ether, "swapper maxStepIn");
    }

    function test_deployV2Stack_keeperCollectsAndForwards() public onlyFork {
        acceptV2Ownership(s, p);
        // the treasury takes its lp share through a fee swapper (eth only, DESIGN section 7)
        FeeAutoSwapperV2 swapper = _deployTreasurySwapper();
        vm.prank(LIVE_OWNER);
        s.escrow.addDepositor(address(swapper), false); // D33

        LaunchV2Lib.Launch memory l = _launch(address(treasury));
        l.cfg.locker.rewardRecipients[0] = address(swapper);
        LaunchV2Lib.Target memory t = _target();
        (, uint256 value) = LaunchV2Lib.preflight(t, l, LIVE_OWNER);
        vm.deal(LIVE_OWNER, LIVE_OWNER.balance + value);
        vm.prank(LIVE_OWNER);
        address coin = s.factory.deployTokenAsOwner{value: value}(l.cfg, l.protocolBps);
        swapper.setup(coin);

        // past the anti sniper window, then trade both ways
        vm.warp(block.timestamp + 70 minutes);
        PoolKey memory key = s.locker.tokenRewards(coin).poolKey;
        (, uint256 bought) = swapExactIn(key, true, 1 ether, address(this), "");
        swapExactIn(key, false, bought / 2, address(this), "");
        swapExactIn(key, true, 0.5 ether, address(this), "");

        uint256 treasuryBefore = address(treasury).balance;
        uint256 controllerBefore =
            address(s.controller).balance + s.escrow.balances(address(s.controller), address(0));
        vm.prank(keeperCaller);
        s.keeper.collectAndForward(coin, false, 0);

        assertGt(address(treasury).balance, treasuryBefore, "lp eth flushed to the treasury");
        assertEq(address(swapper).balance, 0, "swapper flushed");
        assertGt(IERC20(coin).balanceOf(address(swapper)), 0, "coin side waits for convert");
        assertGt(
            address(s.controller).balance + s.escrow.balances(address(s.controller), address(0)),
            controllerBefore,
            "protocol slot paid"
        );
        assertEq(address(s.keeper).balance, 0, "keeper holds no eth");
        assertEq(IERC20(coin).balanceOf(address(s.keeper)), 0, "keeper holds no coin");
        assertEq(address(s.locker).balance, 0, "locker holds no eth");
    }

    // ══════════════════════════════════════════════════════════════════════
    // launch config and script
    // ══════════════════════════════════════════════════════════════════════

    /// @dev The script end to end with a signer that is not the owner: env
    ///      target, parse, preflight, snapshot dry run, then it stops before
    ///      the broadcast leg. Nothing is launched.
    function test_launchV2Coin_script_dryRunOnly() public onlyFork {
        acceptV2Ownership(s, p);
        vm.setEnv("FACTORY_V2", vm.toString(address(s.factory)));
        vm.setEnv("HOOK_V2", vm.toString(address(s.hook)));
        vm.setEnv("LOCKER_V2", vm.toString(address(s.locker)));
        vm.setEnv("MEV_V2", vm.toString(address(s.mev)));
        LaunchV2Coin script = new LaunchV2Coin();
        LaunchV2Lib.Target memory t = script.target();
        assertEq(t.factory, address(s.factory), "env target");
        string memory json = _exampleJson();
        address predicted = s.factory.predictToken(LIVE_OWNER, LaunchV2Lib.parse(json, t).cfg);
        script.run(json);
        assertEq(predicted.code.length, 0, "dry run only");
        assertFalse(s.factory.isCoin(predicted), "no record");
    }

    function test_launchConfig_embeddedCopyMatchesFile() public {
        try vm.readFile(LaunchV2Lib.EXAMPLE_PATH) returns (string memory j) {
            // compare parsed values, not bytes (the file is pretty printed)
            LaunchV2Lib.Target memory t;
            assertEq(
                keccak256(abi.encode(LaunchV2Lib.parse(j, t))),
                keccak256(abi.encode(LaunchV2Lib.parse(EXAMPLE_JSON, t))),
                "embedded EXAMPLE_JSON drifted from example.json"
            );
        } catch {
            // no fs read permission for script/v2/launch-configs: nothing to compare
            vm.skip(true);
        }
    }

    // ── helpers ───────────────────────────────────────────────────────────

    function _target() internal view returns (LaunchV2Lib.Target memory t) {
        t.factory = address(s.factory);
        t.hook = address(s.hook);
        t.locker = address(s.locker);
        t.mev = address(s.mev);
    }

    function _exampleJson() internal view returns (string memory) {
        try vm.readFile(LaunchV2Lib.EXAMPLE_PATH) returns (string memory j) {
            return j;
        } catch {
            return EXAMPLE_JSON;
        }
    }

    /// @dev Example config with the treasury placeholder swapped for a deployed treasury contract.
    function _launch(address treasury_) internal view returns (LaunchV2Lib.Launch memory l) {
        l = LaunchV2Lib.parse(_exampleJson(), _target());
        address placeholder = l.cfg.fee.bountyRecipient;
        assertEq(l.cfg.locker.rewardRecipients[0], placeholder, "slot is the treasury");
        assertFalse(l.cfg.restriction.restricted, "example coin is not restricted");
        l.cfg.fee.bountyRecipient = payable(treasury_);
        l.cfg.locker.rewardRecipients[0] = treasury_;
    }

    function _buyThenSell(address coin) internal {
        PoolKey memory key = s.locker.tokenRewards(coin).poolKey;
        (, uint256 bought) = swapExactIn(key, true, 0.05 ether, address(this), "");
        assertGt(bought, 0, "bought");
        uint256 ethBefore = address(this).balance;
        swapExactIn(key, false, bought / 2, address(this), "");
        assertGt(address(this).balance, ethBefore, "sold");
    }
}
