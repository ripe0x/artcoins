// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// package i1, part 2: credits engine style treasuries as the bounty recipient
// (and the 80% locker slot) of a real factory launch. one test per receive
// shape (CREDITS-ENGINE-INTERFACE.md section 2). every one must keep the pool
// swappable both ways, route the bounty leg to the treasury or its escrow
// balance, the protocol leg to the controller, and the locker share to the
// treasury or its escrow balance.

import {IntegrationV2Base} from "./IntegrationV2Base.sol";
import {
    I1AccountingTreasury,
    I1EmptyTreasury,
    I1FallbackTreasury,
    I1GasBurnerTreasury,
    I1ProxyTreasury,
    I1RevertingTreasury,
    I1StreamTreasury,
    I1TakeTreasury,
    I1TreasuryLogic
} from "./mocks/I1Mocks.sol";

import {IArtCoinsFeeEscrowV2} from "../../../src/v2/interfaces/IArtCoinsFeeEscrowV2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Vm} from "forge-std/Vm.sol";

contract TreasuryMocksV2ForkTest is IntegrationV2Base {
    bytes32 internal constant REWARD_DELIVERED_SIG =
        keccak256("RewardDelivered(address,address,address,uint256,bool)");
    bytes32 internal constant REWARDS_COLLECTED_SIG =
        keccak256("RewardsCollected(address,uint256,uint256)");

    // ── helpers ───────────────────────────────────────────────────────────

    function _launchWith(address treasury) internal returns (address coin, PoolKey memory key) {
        coin = _ownerLaunch(_creditsConfig(treasury));
        key = _key(coin);
        _pastWindow();
    }

    /// buy then sell. every bounty wei is pushed to `treasury` or credited to
    /// it in the escrow; the protocol leg reaches the controller.
    function _trade(PoolKey memory key, address treasury)
        internal
        returns (Legs memory l, uint256 pushed, uint256 escrowed)
    {
        uint256 t0 = treasury.balance;
        uint256 e0 = _escrowed(treasury);
        uint256 c0 = address(v2.controller).balance;
        vm.recordLogs();
        _buyAndSell(key, 0.5 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        l = _legs(logs);
        (pushed, escrowed) = _delivered(logs, treasury);
        assertEq(l.splits, 2, "buy and sell both skimmed");
        assertGt(l.bounty, 0);
        assertEq(pushed + escrowed, l.bounty, "every bounty wei delivered");
        assertEq(treasury.balance - t0, pushed, "pushed amount arrived");
        assertEq(_escrowed(treasury) - e0, escrowed, "escrowed amount credited");
        assertEq(address(v2.controller).balance - c0, l.protocol, "protocol leg to the controller");
        assertEq(l.refunded, 0);
        _assertHookHoldsNothing(key);
    }

    /// locker collect: the treasury's 80% slot is pushed (150k gas) or escrowed.
    function _collect(address coin, address treasury, bool ethPushLands) internal {
        uint256 t0 = treasury.balance;
        uint256 e0 = _escrowed(treasury);
        uint256 k0 = IERC20(coin).balanceOf(treasury);
        vm.recordLogs();
        vm.prank(keeperCaller);
        v2.locker.collectRewards(coin);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 a0;
        uint256 a1;
        uint256 ethPushed;
        uint256 ethEscrowed;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory g = logs[i];
            if (g.emitter != address(v2.locker)) continue;
            if (g.topics[0] == REWARDS_COLLECTED_SIG) {
                (a0, a1) = abi.decode(g.data, (uint256, uint256));
            } else if (
                g.topics[0] == REWARD_DELIVERED_SIG
                    && address(uint160(uint256(g.topics[3]))) == treasury
                    && g.topics[2] == bytes32(0)
            ) {
                (uint256 amt, bool esc) = abi.decode(g.data, (uint256, bool));
                if (esc) ethEscrowed += amt;
                else ethPushed += amt;
            }
        }
        assertGt(a0, 0, "eth lp fees");
        assertGt(a1, 0, "coin lp fees");
        uint256 share0 = (a0 * 8000) / 10_000;
        assertEq(ethPushed + ethEscrowed, share0, "treasury slot eth delivered");
        if (ethPushLands) {
            assertEq(treasury.balance - t0, share0, "locker push landed");
        } else {
            assertEq(_escrowed(treasury) - e0, share0, "locker push escrowed");
            assertEq(treasury.balance, t0);
        }
        assertEq(
            IERC20(coin).balanceOf(treasury) - k0,
            (a1 * 8000) / 10_000,
            "coin share by transfer, no callback"
        );
    }

    // ── 2a. no code ───────────────────────────────────────────────────────

    function test_i1_treasury_noCode_eoa_pushLands() public onlyFork {
        address eoa = makeAddr("i1.treasuryEoa");
        vm.deal(eoa, 5 ether); // v1 bricked every swap once an eoa recipient held 0.01 eth
        (address coin, PoolKey memory key) = _launchWith(eoa);
        (, uint256 pushed, uint256 escrowed) = _trade(key, eoa);
        assertGt(pushed, 0);
        assertEq(escrowed, 0, "nothing escrowed");
        _collect(coin, eoa, true);
    }

    // ── 2b. empty payable fallback ────────────────────────────────────────

    function test_i1_treasury_emptyPayableFallback_pushLands() public onlyFork {
        I1FallbackTreasury t = new I1FallbackTreasury();
        (address coin, PoolKey memory key) = _launchWith(address(t));
        (, uint256 pushed, uint256 escrowed) = _trade(key, address(t));
        assertGt(pushed, 0);
        assertEq(escrowed, 0);
        _trade(key, address(t)); // again, with a balance
        _collect(coin, address(t), true);
    }

    // ── 2c. fallback that reverts ─────────────────────────────────────────

    function test_i1_treasury_revertingFallback_escrowed_thenClaimTo() public onlyFork {
        I1RevertingTreasury t = new I1RevertingTreasury();
        (address coin, PoolKey memory key) = _launchWith(address(t));
        (Legs memory l, uint256 pushed, uint256 escrowed) = _trade(key, address(t));
        assertEq(pushed, 0);
        assertEq(escrowed, l.bounty, "bounty escrowed");
        _collect(coin, address(t), false);

        // a third party claim reverts (the treasury rejects eth) and the balance stays
        uint256 owed = _escrowed(address(t));
        vm.prank(stranger);
        vm.expectRevert(IArtCoinsFeeEscrowV2.NativeTransferFailed.selector);
        v2.escrow.claim(address(t), address(0));
        assertEq(_escrowed(address(t)), owed);
        // the fee owner pulls to a payable target
        address payable target = payable(makeAddr("i1.revertingTarget"));
        t.pull(v2.escrow, target);
        assertEq(target.balance, owed, "claimTo delivered");
        assertEq(_escrowed(address(t)), 0);
        _trade(key, address(t)); // still swappable
    }

    // ── 2d. fallback that burns all gas ───────────────────────────────────

    /// gas of a warm 0.5 eth buy on `key` (pool and escrow slots already touched).
    function _warmBuyGas(PoolKey memory key) internal returns (uint256 used) {
        _buy(key, 0.05 ether);
        uint256 g = gasleft();
        _buy(key, 0.5 ether);
        used = g - gasleft();
    }

    function test_i1_treasury_gasBurner_escrowed_swapGasBounded() public onlyFork {
        address eoa = makeAddr("i1.refEoa");
        (, PoolKey memory refKey) = _launchWith(eoa);
        uint256 refGas = _warmBuyGas(refKey);

        I1GasBurnerTreasury t = new I1GasBurnerTreasury();
        (address coin, PoolKey memory key) = _launchWith(address(t));
        uint256 used = _warmBuyGas(key);
        // stipend only push: the burner can spend 2,300 gas, then a warm escrow credit
        assertLt(used, refGas + 30_000, "gas burner bounded by the stipend");
        (Legs memory l, uint256 pushed, uint256 escrowed) = _trade(key, address(t));
        assertEq(pushed, 0);
        assertEq(escrowed, l.bounty, "bounty escrowed");
        _collect(coin, address(t), false);
    }

    // ── 2e. fallback that calls poolManager.take ──────────────────────────

    function test_i1_treasury_takeFromPoolManager_failsInStipend_escrowed() public onlyFork {
        for (uint8 mode; mode < 2; ++mode) {
            I1TakeTreasury t = new I1TakeTreasury(pm, mode);
            (address coin, PoolKey memory key) = _launchWith(address(t));
            t.setCoin(coin);
            uint256 coinBefore = IERC20(coin).balanceOf(address(this));
            (Legs memory l, uint256 pushed, uint256 escrowed) = _trade(key, address(t));
            assertEq(pushed, 0, "take cannot run inside 2,300 gas");
            assertEq(escrowed, l.bounty, "leg lands in escrow");
            assertEq(t.tookOk(), 0, "no take survived");
            assertEq(IERC20(coin).balanceOf(address(t)), 0, "no coin taken");
            assertEq(pm.balanceOf(address(t), 0), 0, "no claim minted");
            assertGt(IERC20(coin).balanceOf(address(this)), coinBefore, "swapper kept its coin");
            // outside a swap the PoolManager is locked: the locker push (150k gas) fails too
            _collect(coin, address(t), false);
        }
    }

    // ── 2f. proxy style receiver ──────────────────────────────────────────

    function test_i1_treasury_proxyColdSload_escrowed_claimRunsLogic() public onlyFork {
        I1TreasuryLogic logic = new I1TreasuryLogic();
        I1ProxyTreasury t = new I1ProxyTreasury(address(logic));
        (address coin, PoolKey memory key) = _launchWith(address(t));
        (Legs memory l, uint256 pushed, uint256 escrowed) = _trade(key, address(t));
        assertEq(pushed, 0, "cold sload plus delegatecall exceed the stipend");
        assertEq(escrowed, l.bounty);
        assertEq(t.pushes(), 0);

        // anyone flushes it with full gas; the logic's accounting runs
        uint256 owed = _escrowed(address(t));
        vm.prank(stranger);
        v2.escrow.claim(address(t), address(0));
        assertEq(t.received(), owed, "logic accounted the claim");
        assertEq(t.pushes(), 1);
        assertEq(address(t).balance, owed);
        // the locker push carries 150k gas: enough for the proxy
        _collect(coin, address(t), true);
    }

    // ── 2g. accounting over 2,300 gas ─────────────────────────────────────

    function test_i1_treasury_accountingOverStipend_escrowed_thenAnyoneClaims() public onlyFork {
        I1AccountingTreasury t = new I1AccountingTreasury();
        (address coin, PoolKey memory key) = _launchWith(address(t));
        (Legs memory l, uint256 pushed, uint256 escrowed) = _trade(key, address(t));
        assertEq(pushed, 0, "sstore needs more than the stipend");
        assertEq(escrowed, l.bounty);
        assertEq(t.received(), 0);

        uint256 owed = _escrowed(address(t));
        vm.prank(stranger);
        v2.escrow.claim(address(t), address(0));
        assertEq(t.received(), owed, "claim delivers with full gas");
        assertEq(t.pushes(), 1);
        assertEq(_escrowed(address(t)), 0);
        _collect(coin, address(t), true);
        assertEq(t.pushes(), 2, "locker push ran the accounting");
    }

    // ── 2h. v1 style streamForward implementer ────────────────────────────

    function test_i1_treasury_v1StreamForward_neverCalled() public onlyFork {
        I1StreamTreasury t = new I1StreamTreasury();
        vm.deal(address(t), 50 ether); // far above the v1 probe floor
        (address coin, PoolKey memory key) = _launchWith(address(t));
        vm.expectCall(
            address(t), abi.encodeWithSelector(I1StreamTreasury.streamForward.selector), 0
        );
        (, uint256 pushed, uint256 escrowed) = _trade(key, address(t));
        assertGt(pushed, 0, "empty receive gets the stipend push");
        assertEq(escrowed, 0);
        vm.prank(keeperCaller);
        v2.keeper.collectAndForward(coin, true, 0);
        assertEq(t.streams(), 0, "never probed by hook, locker or keeper");
    }
}
