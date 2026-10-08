// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// package i1: v2 end to end suite, part 1 (DESIGN section 8 row i1).
//   1  owner launch while deprecated, then open, stranger launch, both swap
//   8  version and discovery
//   9  owner surface after launch, rescue vs owed balances
//   10 gas table (numbers in docs/v2/review/i1-notes.md)
// the other parts live under test/v2/integration/. every test forks mainnet at
// the harness pin, deploys the stack with the deploy script's routine and
// launches through the real factory. skips cleanly without an rpc.
//
// run:
//   /tmp/claude-0/forge.sh test --match-path "test/v2/IntegrationV2*" \
//     --skip "test/v2/review/**" --skip "test/v2/review-v2/**" -vv

import {IntegrationV2Base} from "./integration/IntegrationV2Base.sol";
import {
    I1EmptyTreasury,
    I1GasBurnerTreasury,
    I1StreamTreasury
} from "./integration/mocks/I1Mocks.sol";

import {Constants} from "../../src/Constants.sol";
import {ArtCoinsFeeEscrowV2} from "../../src/v2/ArtCoinsFeeEscrowV2.sol";
import {ArtCoinsTokenV2} from "../../src/v2/ArtCoinsTokenV2.sol";
import {FeeAutoSwapperV2} from "../../src/v2/FeeAutoSwapperV2.sol";
import {IArtCoinsFactoryV2} from "../../src/v2/interfaces/IArtCoinsFactoryV2.sol";
import {IArtCoinsFeeEscrowV2} from "../../src/v2/interfaces/IArtCoinsFeeEscrowV2.sol";
import {IArtCoinsHookV2} from "../../src/v2/interfaces/IArtCoinsHookV2.sol";
import {IArtCoinsLpLockerV2} from "../../src/v2/interfaces/IArtCoinsLpLockerV2.sol";
import {IBurnRouterV2} from "../../src/v2/interfaces/IBurnRouterV2.sol";
import {IFeeAutoSwapperV2} from "../../src/v2/interfaces/IFeeAutoSwapperV2.sol";
import {ArtCoinsLpLockerV2} from "../../src/v2/lp-lockers/ArtCoinsLpLockerV2.sol";
import {ArtCoinsDeployerV2} from "../../src/v2/utils/ArtCoinsDeployerV2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";

contract IntegrationV2ForkTest is IntegrationV2Base {
    using PoolIdLibrary for PoolKey;

    // ══════════════════════════════════════════════════════════════════════
    // 1. owner launch while deprecated, then open
    // ══════════════════════════════════════════════════════════════════════

    function test_i1_ownerLaunchWhileDeprecated_thenOpen_strangerLaunch_bothPoolsSwap()
        public
        onlyFork
    {
        I1EmptyTreasury treasury = new I1EmptyTreasury();
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c = _creditsConfig(address(treasury));
        assertTrue(v2.factory.deprecated(), "stack ships deprecated");
        uint256 fee = v2.factory.deployFee();
        assertEq(fee, 0.069 ether, "deploy fee");

        // closed to the public
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        vm.expectRevert(IArtCoinsFactoryV2.Deprecated.selector);
        v2.factory.deployToken{value: fee}(c);

        // owner launch of the credits engine coin while deprecated
        address coin1 = _ownerLaunch(c);
        PoolId pid1 = _pid(coin1);
        assertTrue(v2.factory.isArtCoin(coin1), "coin1 recorded");
        IArtCoinsHookV2.SkimConfig memory sc = v2.hook.skimConfig(pid1);
        assertEq(sc.bountyRecipient, address(treasury), "bounty = treasury");
        assertEq(sc.protocolRecipient, address(v2.controller), "protocol injected");
        assertEq(sc.referralPayout, address(v2.escrow), "referral payout = escrow (D57)");
        assertFalse(_token(coin1).restricted(), "credits coin is not restricted");
        address[] memory rr = v2.locker.rewardRecipients(coin1);
        assertEq(rr.length, 2, "project slot + protocol slot");
        assertEq(rr[0], address(treasury));
        assertEq(rr[1], address(v2.controller));

        // open, then a stranger launches the same config and pays the fee
        vm.prank(LIVE_OWNER);
        v2.factory.setDeprecated(false);
        uint256 teamBefore = LIVE_OWNER.balance;
        uint256 strangerBefore = stranger.balance;
        address predicted = v2.factory.predictToken(stranger, c);
        vm.prank(stranger);
        address coin2 = v2.factory.deployToken{value: fee}(c);
        assertEq(coin2, predicted, "predicted");
        assertTrue(coin2 != coin1, "sender in salt");
        assertEq(LIVE_OWNER.balance - teamBefore, fee, "fee to team recipient");
        assertEq(strangerBefore - stranger.balance, fee, "stranger paid exactly the fee");
        assertEq(
            v2.locker.rewardRecipients(coin2)[1], address(v2.controller), "default protocol slot"
        );
        assertEq(v2.locker.rewardBps(coin2)[1], v2.factory.defaultProtocolFeeBps());

        // both pools swap both ways, inside the anti sniper window; the
        // treasury takes the bounty leg directly (empty receive), the
        // controller the protocol leg.
        address[2] memory coins = [coin1, coin2];
        for (uint256 i; i < 2; ++i) {
            PoolKey memory key = _key(coins[i]);
            uint256 t0 = address(treasury).balance;
            uint256 p0 = address(v2.controller).balance;
            vm.recordLogs();
            _buyAndSell(key, 0.1 ether);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            Legs memory l = _legs(logs);
            assertEq(l.splits, 2, "two skims");
            assertEq(address(treasury).balance - t0, l.bounty, "bounty pushed to the treasury");
            assertEq(
                address(v2.controller).balance - p0, l.protocol, "protocol leg to the controller"
            );
            assertEq(l.refunded, 0);
            _assertHookHoldsNothing(key);
        }
        assertEq(_owed(), 0, "nothing escrowed");
    }

    // ══════════════════════════════════════════════════════════════════════
    // 8. version and discovery
    // ══════════════════════════════════════════════════════════════════════

    function test_i1_versionAndDiscovery_launchEventDecodesToConfigHash() public onlyFork {
        I1EmptyTreasury treasury = new I1EmptyTreasury();
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c = _creditsConfig(address(treasury));
        address predicted = v2.factory.predictToken(LIVE_OWNER, c);
        bytes32 h = v2.factory.configHash(c);
        assertEq(h, keccak256(abi.encode(c)), "configHash = keccak(abi.encode(c))");

        vm.recordLogs();
        address coin = _ownerLaunch(c);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(coin, predicted, "predictToken");
        PoolId pid = _pid(coin);

        // discovery reads
        IArtCoinsHookV2.PoolInfo memory info = v2.hook.poolInfo(pid);
        assertEq(info.version, 2, "hook.poolInfo(pid).version == 2");
        assertEq(info.version, Constants.STACK_VERSION);
        assertEq(info.launcher, address(v2.factory), "launcher");
        assertEq(info.token, coin);
        assertEq(info.locker, address(v2.locker));
        assertEq(info.mevModule, address(v2.mev));
        assertFalse(info.restricted);
        assertEq(info.createdAt, uint40(vm.getBlockTimestamp()));
        assertTrue(v2.hook.isOfficialPool(pid), "official pool");
        assertTrue(v2.factory.isArtCoin(coin), "factory.isArtCoin");
        assertFalse(v2.factory.isArtCoin(address(treasury)));
        assertEq(_token(coin).launcherVersion(), 2, "token.launcherVersion() == 2");
        assertEq(_token(coin).launcher(), address(v2.factory));
        assertEq(v2.factory.STACK_VERSION(), 2);
        IArtCoinsFactoryV2.DeploymentInfoV2 memory di = v2.factory.deploymentInfo(coin);
        assertEq(di.token, coin);
        assertEq(di.hook, address(v2.hook));
        assertEq(di.locker, address(v2.locker));
        assertEq(di.mevModule, address(v2.mev));
        assertEq(PoolId.unwrap(di.poolId), PoolId.unwrap(pid));
        assertEq(di.version, 2);
        assertEq(di.launchedAt, uint40(vm.getBlockTimestamp()));
        assertEq(di.extensions.length, 0);
        assertEq(_token(coin).canonicalPoolId(), PoolId.unwrap(pid), "token names the pool");
        vm.expectRevert(IArtCoinsFactoryV2.NotFound.selector);
        v2.factory.deploymentInfo(address(treasury));

        // the launch event: one TokenCreatedV2 from the factory, decodes to the config hash
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory g = logs[i];
            if (
                g.emitter != address(v2.factory)
                    || g.topics[0] != IArtCoinsFactoryV2.TokenCreatedV2.selector
            ) {
                continue;
            }
            ++found;
            assertEq(address(uint160(uint256(g.topics[1]))), LIVE_OWNER, "sender");
            assertEq(address(uint160(uint256(g.topics[2]))), coin, "token");
            assertEq(g.topics[3], PoolId.unwrap(pid), "poolId");
            (
                uint16 stackVersion,
                bytes32 cfgHash,
                address protocolRecipient,
                address referralPayout,
                uint16 protocolBps,
                uint256 poolSupply,
                uint256 extensionsSupply,
                IArtCoinsFactoryV2.DeploymentConfigV2 memory cfg
            ) = abi.decode(
                g.data,
                (
                    uint16,
                    bytes32,
                    address,
                    address,
                    uint16,
                    uint256,
                    uint256,
                    IArtCoinsFactoryV2.DeploymentConfigV2
                )
            );
            assertEq(stackVersion, 2, "event version");
            assertEq(cfgHash, h, "event configHash");
            assertEq(keccak256(abi.encode(cfg)), cfgHash, "event config hashes to configHash");
            assertEq(protocolRecipient, address(v2.controller));
            assertEq(referralPayout, address(v2.escrow));
            assertEq(protocolBps, PROTOCOL_BPS);
            assertEq(poolSupply, Constants.DEFAULT_TOKEN_SUPPLY);
            assertEq(extensionsSupply, 0);
            assertEq(cfg.fee.bountyRecipient, address(treasury));
            assertFalse(cfg.restriction.restricted);
        }
        assertEq(found, 1, "one TokenCreatedV2");
    }

    // ══════════════════════════════════════════════════════════════════════
    // 9. owner surface after launch
    // ══════════════════════════════════════════════════════════════════════

    /// every per coin field the owner could reach, in one hash.
    function _perCoin(address coin, FeeAutoSwapperV2 sw) internal view returns (bytes32) {
        PoolId pid = _pid(coin);
        ArtCoinsTokenV2 t = _token(coin);
        (,,, uint24 lpFee) = readSlot0(_key(coin));
        bytes memory a = abi.encode(
            v2.hook.poolInfo(pid),
            v2.hook.skimConfig(pid),
            v2.hook.minProtocolShareBps(pid),
            v2.hook.isOfficialPool(pid),
            v2.locker.tokenRewards(coin),
            v2.mev.schedule(pid),
            lpFee
        );
        bytes memory b = abi.encode(
            t.restricted(),
            t.locked(),
            t.canonicalHook(),
            t.canonicalPoolId(),
            t.poolManager(),
            t.launcher(),
            t.admin()
        );
        bytes memory c = abi.encode(
            sw.endRecipient(),
            sw.artCoin(),
            sw.poolKey(),
            sw.feeEscrow(),
            v2.factory.deploymentInfo(coin),
            v2.factory.isArtCoin(coin)
        );
        return keccak256(bytes.concat(a, b, c));
    }

    function test_i1_ownerSetters_cannotChangePerCoinFields() public onlyFork {
        I1EmptyTreasury treasury = new I1EmptyTreasury();
        FeeAutoSwapperV2 sw = _newSwapper(address(treasury));
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c = _creditsConfig(address(treasury));
        c.locker.rewardRecipients[0] = address(sw);
        address coin = _ownerLaunch(c);
        sw.setup(coin);
        PoolKey memory key = _key(coin);
        _pastWindow();
        _buyAndSell(key, 1 ether);
        vm.prank(LIVE_OWNER);
        v2.burnRouter.initialize(coin, key);

        bytes32 before = _perCoin(coin, sw);
        address other = makeAddr("i1.other");
        I1StreamTreasury otherContract = new I1StreamTreasury();

        // a replacement escrow that knows the hook and locker (D36)
        ArtCoinsFeeEscrowV2 escrow2 = new ArtCoinsFeeEscrowV2(LIVE_OWNER);
        ArtCoinsDeployerV2 deployer2 = new ArtCoinsDeployerV2(address(v2.factory));

        vm.startPrank(LIVE_OWNER);
        // factory: every setter, extreme values
        v2.factory.setDeprecated(false);
        v2.factory.setDeployFee(Constants.MAX_DEPLOY_FEE);
        v2.factory.setDefaultProtocolFeeBps(Constants.MAX_PROTOCOL_FEE_BPS);
        v2.factory.setMinProtocolSkimShareBps(uint16(Constants.BPS));
        v2.factory.setProtocolRecipient(payable(other));
        v2.factory.setReferralPayout(payable(address(otherContract)));
        v2.factory.setTeamFeeRecipient(other);
        address[] memory da = new address[](1);
        da[0] = address(otherContract);
        v2.factory.setDefaultAllowed(da);
        v2.factory.setTokenDeployer(address(deployer2));
        v2.factory.setHook(address(v2.hook), false);
        v2.factory.setLocker(address(v2.locker), false);
        v2.factory.setMevModule(address(v2.mev), false);
        v2.factory.setEscrow(address(v2.escrow), false);
        // hook: globals only
        escrow2.addDepositor(address(v2.hook), true);
        escrow2.addDepositor(address(v2.locker), true);
        v2.hook.setExtensionAllowlist(address(0));
        v2.hook.setLauncher(address(v2.factory), false);
        v2.hook.setLauncher(other, true);
        v2.hook.setFeeEscrow(address(escrow2));
        // locker: globals only
        v2.locker.setKeeperRewardBps(Constants.LOCKER_KEEPER_BPS_MAX);
        v2.locker.setKeeperRewardCap(Constants.LOCKER_KEEPER_CAP_MAX);
        v2.locker.setLauncher(address(v2.factory), false);
        v2.locker.setFeeEscrow(address(escrow2));
        // escrow
        v2.escrow.addDepositor(other, false);
        v2.escrow.removeDepositor(address(v2.controller));
        // protocol fee controller, burn router (protocol side, not per coin)
        v2.controller.setSplit(Constants.PFC_MIN_TREASURY_BPS);
        v2.controller.setTreasury(other);
        v2.controller.setBurnRouter(other);
        v2.burnRouter.setMaxImpactBps(Constants.BURN_IMPACT_MAX);
        v2.burnRouter.setMinProcessThreshold(type(uint96).max);
        v2.burnRouter.setOpenTabCaller(other);
        // the coin's fee swapper: tunables only
        sw.setMaxSlippageBps(Constants.SWAPPER_SLIPPAGE_MAX);
        sw.setMinBlocksBetweenConverts(Constants.SWAPPER_MIN_BLOCKS_MAX);
        sw.setMaxStepIn(1);
        sw.setMaxImpactBps(Constants.BURN_IMPACT_MAX);
        sw.setSpotFloorBps(Constants.SPOT_FLOOR_MIN_BPS);
        vm.stopPrank();

        assertEq(_perCoin(coin, sw), before, "no owner setter reached a per coin field");
        assertEq(
            v2.hook.skimConfig(_pid(coin)).protocolRecipient,
            address(v2.controller),
            "protocol frozen"
        );
        assertEq(
            v2.locker.rewardRecipients(coin)[1], address(v2.controller), "protocol slot frozen"
        );

        // the pool still swaps and pays the frozen recipients; failed pushes
        // would land in the new escrow (a global pointer, by design)
        uint256 t0 = address(treasury).balance;
        uint256 p0 = address(v2.controller).balance;
        vm.recordLogs();
        uint256 got = _buy(key, 0.5 ether);
        Legs memory l = _legs(vm.getRecordedLogs());
        assertEq(
            l.bounty + l.protocol,
            (0.5 ether * uint256(BASELINE)) / D,
            "skim still the frozen baseline"
        );
        uint256 base = l.bounty + l.protocol;
        assertEq(l.protocol, base - (base * BOUNTY_BPS) / 10_000, "bounty share still frozen");
        _sell(key, got / 2);
        assertEq(address(treasury).balance - t0 >= l.bounty, true, "bounty to the frozen recipient");
        assertGt(
            address(v2.controller).balance - p0, l.protocol, "protocol to the frozen recipient"
        );
        assertEq(other.balance, 0, "new protocol recipient gets nothing from this pool");
        assertEq(escrow2.totalOwed(address(0)), 0, "nothing failed");

        // the locker still collects to the frozen slots
        vm.prank(keeperCaller);
        v2.locker.collectRewards(coin);
        assertGt(IERC20(coin).balanceOf(address(sw)), 0, "swapper slot paid");
        assertEq(_perCoin(coin, sw), before, "still frozen after trading");
    }

    function test_i1_rescue_cannotTouchOwedBalances() public onlyFork {
        I1GasBurnerTreasury burner = new I1GasBurnerTreasury();
        FeeAutoSwapperV2 sw = _newSwapper(address(new I1EmptyTreasury()));
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c = _creditsConfig(address(burner));
        c.locker.rewardRecipients[0] = address(sw);
        address coin = _ownerLaunch(c);
        sw.setup(coin);
        PoolKey memory key = _key(coin);
        _pastWindow();
        _buyAndSell(key, 1 ether);
        vm.prank(LIVE_OWNER);
        v2.burnRouter.initialize(coin, key);

        uint256 owed = _escrowed(address(burner));
        assertGt(owed, 0, "bounty escrowed for the burner");
        assertEq(_owed(), owed);
        assertEq(address(v2.escrow).balance, owed, "escrow holds exactly what it owes");

        vm.startPrank(LIVE_OWNER);
        // escrow: nothing beyond owed
        vm.expectRevert(
            abi.encodeWithSelector(IArtCoinsFeeEscrowV2.RescueExceedsExcess.selector, 1, 0)
        );
        v2.escrow.rescue(address(0), LIVE_OWNER, 1);
        vm.stopPrank();
        vm.deal(address(v2.escrow), address(v2.escrow).balance + 1 ether); // stray eth
        vm.startPrank(LIVE_OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtCoinsFeeEscrowV2.RescueExceedsExcess.selector, 1 ether + 1, 1 ether
            )
        );
        v2.escrow.rescue(address(0), LIVE_OWNER, 1 ether + 1);
        v2.escrow.rescue(address(0), LIVE_OWNER, 1 ether); // stray only
        assertEq(address(v2.escrow).balance, owed, "owed untouched");
        assertEq(_escrowed(address(burner)), owed);

        // hook: holds nothing between swaps, so its rescue has nothing to take
        assertEq(address(v2.hook).balance, 0);
        vm.expectRevert(IArtCoinsHookV2.EthTransferFailed.selector);
        v2.hook.rescue(address(0), LIVE_OWNER, 1);
        vm.expectRevert();
        v2.hook.rescueClaims(key.currency0, LIVE_OWNER, 1);

        // locker: the lp position nfts are not rescuable, it holds no fees
        uint256 positionId = v2.locker.tokenRewards(coin).positionId;
        address posm = address(v2.locker.positionManager()); // read before expectRevert
        vm.expectRevert(ArtCoinsLpLockerV2.RescueForbidden.selector);
        v2.locker.rescue(posm, LIVE_OWNER, positionId);
        assertEq(address(v2.locker).balance, 0);
        assertEq(IERC20(coin).balanceOf(address(v2.locker)), 0);

        // swapper: never the coin or eth (fees owed to the end recipient)
        vm.expectRevert(abi.encodeWithSelector(IFeeAutoSwapperV2.CannotRescue.selector, coin));
        sw.rescue(coin, LIVE_OWNER, 1);
        vm.expectRevert(abi.encodeWithSelector(IFeeAutoSwapperV2.CannotRescue.selector, address(0)));
        sw.rescue(address(0), LIVE_OWNER, 1);

        // burn router: never the coin or eth
        vm.expectRevert(abi.encodeWithSelector(IBurnRouterV2.CannotRescue.selector, coin));
        v2.burnRouter.rescue(coin, LIVE_OWNER, 1);
        vm.expectRevert(abi.encodeWithSelector(IBurnRouterV2.CannotRescue.selector, address(0)));
        v2.burnRouter.rescue(address(0), LIVE_OWNER, 1);
        vm.stopPrank();

        // the owed balance still pays out to its owner (claimTo: the burner
        // eats any gas, so the fee owner sends it elsewhere)
        address payable target = payable(makeAddr("i1.burnerTarget"));
        vm.prank(address(burner));
        v2.escrow.claimTo(address(burner), address(0), target);
        assertEq(target.balance, owed, "owner of the fee got it");
        assertEq(_owed(), 0);
    }

    // ══════════════════════════════════════════════════════════════════════
    // 10. gas table
    // ══════════════════════════════════════════════════════════════════════

    /// marks every contract on the hot paths cold, so each number below
    /// approximates a fresh transaction (minus the 21k base and calldata).
    function _coolAll(address coin, address sw) internal {
        vm.cool(POOL_MANAGER);
        vm.cool(address(v2.hook));
        vm.cool(address(v2.locker));
        vm.cool(address(v2.escrow));
        vm.cool(address(v2.mev));
        vm.cool(address(v2.controller));
        vm.cool(address(v2.burnRouter));
        vm.cool(address(v2.factory));
        vm.cool(address(v2.tokenDeployer));
        vm.cool(POSITION_MANAGER);
        vm.cool(PERMIT2);
        vm.cool(address(swapRouter));
        if (coin != address(0)) vm.cool(coin);
        if (sw != address(0)) vm.cool(sw);
    }

    function test_i1_gasTable() public onlyFork {
        I1EmptyTreasury treasury = new I1EmptyTreasury();
        FeeAutoSwapperV2 sw = _newSwapper(address(treasury));
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c = _creditsConfig(address(treasury));
        c.locker.rewardRecipients[0] = address(sw);
        uint256 fee = v2.factory.deployFee();
        vm.deal(LIVE_OWNER, LIVE_OWNER.balance + fee);

        _coolAll(address(0), address(0));
        vm.prank(LIVE_OWNER);
        uint256 g = gasleft();
        address coin = v2.factory.deployTokenAsOwner{value: fee}(c, PROTOCOL_BPS);
        uint256 gLaunch = g - gasleft();

        sw.setup(coin);
        PoolKey memory key = _key(coin);
        vm.prank(LIVE_OWNER);
        v2.burnRouter.initialize(coin, key);
        _pastWindow();
        _buyAndSell(key, 1 ether); // seed both fee sides and the coin balance
        vm.roll(vm.getBlockNumber() + 1);

        vm.deal(address(this), address(this).balance + 1 ether);
        _coolAll(coin, address(sw));
        g = gasleft();
        swapExactIn(key, true, 0.1 ether, address(this), "");
        uint256 gBuy = g - gasleft();

        uint256 sellAmt = IERC20(coin).balanceOf(address(this)) / 4;
        _coolAll(coin, address(sw));
        g = gasleft();
        swapExactIn(key, false, sellAmt, address(this), "");
        uint256 gSell = g - gasleft();

        _coolAll(coin, address(sw));
        g = gasleft();
        v2.locker.collectRewards(coin);
        uint256 gCollect = g - gasleft();

        vm.roll(vm.getBlockNumber() + 1);
        _coolAll(coin, address(sw));
        g = gasleft();
        sw.convert(0);
        uint256 gConvert = g - gasleft();

        (bool ok,) = address(v2.burnRouter).call{value: 0.5 ether}("");
        assertTrue(ok);
        vm.roll(vm.getBlockNumber() + 1);
        _coolAll(coin, address(sw));
        g = gasleft();
        v2.burnRouter.processBurn(0);
        uint256 gBurn = g - gasleft();

        console2.log("i1 gas: launch (deployTokenAsOwner, 3 positions)", gLaunch);
        console2.log("i1 gas: buy 0.1 eth exact in (PoolSwapTest)", gBuy);
        console2.log("i1 gas: sell exact in (PoolSwapTest)", gSell);
        console2.log("i1 gas: locker.collectRewards (2 slots, 3 positions)", gCollect);
        console2.log("i1 gas: swapper.convert", gConvert);
        console2.log("i1 gas: burnRouter.processBurn", gBurn);
        assertGt(gLaunch, 0);
        assertLt(gLaunch, 16_700_000, "launch under the per tx cap");
    }
}
