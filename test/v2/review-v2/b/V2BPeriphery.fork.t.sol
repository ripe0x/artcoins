// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// independent review v2-b: periphery against the real v2 hook on a mainnet fork.
// run: /tmp/claude-0/forge.sh test --match-path "test/v2/review-v2/b/**" \
//   --skip "test/v2/harness/**" --skip "test/v2/review/**" --skip script \
//   --skip src/v2/ArtCoinsFactoryV2.sol --skip "test/v2/FactoryV2*" --skip "test/v2/mocks/FactoryV2*" -vv
// after the fixes (D39) the test_V2Bxx_* tests are regressions: they
// PASS by asserting the fixed outcome. the original attack is kept in a comment
// above each one. tests named test_holds_* PASS when the claim holds.

import {HookV2ForkBase} from "../../mocks/HookV2ForkBase.sol";

import {ArtCoinsTokenV2} from "../../../../src/v2/ArtCoinsTokenV2.sol";
import {ArtCoinsUniv4EthDevBuyV2} from "../../../../src/v2/extensions/ArtCoinsUniv4EthDevBuyV2.sol";
import {
    IArtCoinsUniv4EthDevBuyV2
} from "../../../../src/v2/extensions/interfaces/IArtCoinsUniv4EthDevBuyV2.sol";
import {IArtCoinsFactoryV2} from "../../../../src/v2/interfaces/IArtCoinsFactoryV2.sol";
import {IArtCoinsHookV2} from "../../../../src/v2/interfaces/IArtCoinsHookV2.sol";

import {IArtCoinsFeeEscrowV2} from "../../../../src/v2/interfaces/IArtCoinsFeeEscrowV2.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev Escrow stand in: reports a credit and, on `claimTo`, forwards the
///      payout through `poker`, so the eth arrives from `poker` and not from
///      this contract.
contract V2BPokingEscrow {
    V2BPoker immutable poker;

    constructor(V2BPoker poker_) {
        poker = poker_;
    }

    function balances(address, address) external pure returns (uint256) {
        return 1;
    }

    function setSelfClaimOnly(bool) external {}

    function claimTo(address, address, address payable to) external {
        poker.poke(to);
    }
}

contract V2BPoker {
    function poke(address to) external {
        (bool ok, bytes memory r) = to.call{value: 1 wei}("");
        if (!ok) {
            assembly {
                revert(add(r, 0x20), mload(r))
            }
        }
    }

    receive() external payable {}
}

contract V2BPeripheryForkTest is HookV2ForkBase {
    address internal griefer = makeAddr("v2b-griefer");

    // ── helpers ───────────────────────────────────────────────────────────

    function _devBuyCall(
        ArtCoinsUniv4EthDevBuyV2 d,
        PoolKey memory key,
        address token,
        uint256 value,
        address buyer,
        address refundTo
    ) internal {
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c;
        c.extensions = new IArtCoinsFactoryV2.ExtensionConfigV2[](1);
        c.extensions[0] = IArtCoinsFactoryV2.ExtensionConfigV2({
            extension: address(d),
            msgValue: value,
            extensionBps: 0,
            extensionData: abi.encode(buyer, refundTo, uint128(1))
        });
        c.pool.hook = address(hook);
        d.receiveTokens{value: value}(c, key, token, 0, 0);
    }

    /// dev buy before `initializeMevModule` (factory order): the take to the
    /// recipient lands coin at the buyer.
    function test_holds_devBuy() public onlyFork {
        ArtCoinsTokenV2 token = _newToken(false, bountyEoa, address(hook));
        PoolKey memory key = hook.initializePool(_params(_defaults(bountyEoa), address(token)));
        _modify(key, FULL_LO, FULL_HI, int256(LIQ), 0);
        ArtCoinsUniv4EthDevBuyV2 d = new ArtCoinsUniv4EthDevBuyV2(address(this), POOL_MANAGER);
        address buyer = makeAddr("v2b-buyer");
        _devBuyCall(d, key, address(token), 1 ether, buyer, makeAddr("v2b-refund"));
        assertGt(token.balanceOf(buyer), 0);
    }

    /// partial fill through the real hook: the over charged skim lands in the
    /// escrow under the dev buy contract and is pulled to the refund recipient
    /// in the same call. refund == value - pool input - fair skim.
    function test_holds_devBuy_partialFill_skimRefundReachesRecipient() public onlyFork {
        ArtCoinsTokenV2 token = _newToken(false, bountyEoa, address(hook));
        PoolKey memory key = hook.initializePool(_params(_defaults(bountyEoa), address(token)));
        _modify(key, -600, 0, int256(LIQ), 0); // coin only, about 30 eth deep
        ArtCoinsUniv4EthDevBuyV2 d = new ArtCoinsUniv4EthDevBuyV2(address(this), POOL_MANAGER);
        address refundTo = makeAddr("v2b-refund2");
        address buyer = makeAddr("v2b-buyer2");
        uint256 pmEth0 = POOL_MANAGER.balance;
        _devBuyCall(d, key, address(token), 100 ether, buyer, refundTo);
        uint256 poolIn = POOL_MANAGER.balance - pmEth0;
        assertGt(refundTo.balance, 60 ether, "most eth refunded");
        assertEq(escrow.balances(address(d), address(0)), 0, "no skim left in escrow");
        assertEq(address(d).balance, 0);
        // whatever did not go to the pool or the skim legs came back
        assertLt(100 ether - refundTo.balance - poolIn, 3 ether, "only the fair skim kept");
    }

    /// @dev One launch on a fresh coin and pool through `d`, liquidity in
    ///      [lo, hi]. Returns the eth the pool took, the refund the recipient
    ///      received and the escrow credit `d` claimed, and checks the payout
    ///      identity and the post launch invariant.
    function _launchThrough(
        ArtCoinsUniv4EthDevBuyV2 d,
        address refundTo,
        int24 lo,
        int24 hi,
        uint256 value
    ) internal returns (uint256 spent, uint256 refunded, uint256 claimed, uint256 claims) {
        ArtCoinsTokenV2 tk = _newToken(false, bountyEoa, address(hook));
        PoolKey memory k = hook.initializePool(_params(_defaults(bountyEoa), address(tk)));
        _modify(k, lo, hi, int256(LIQ), 0);
        uint256 before = refundTo.balance;
        vm.recordLogs();
        _devBuyCall(d, k, address(tk), value, makeAddr("v2b08-buyer"), refundTo);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(d)) {
                (spent,, refunded,) = abi.decode(logs[i].data, (uint256, uint256, uint256, address));
            } else if (
                logs[i].emitter == address(escrow)
                    && logs[i].topics[0] == IArtCoinsFeeEscrowV2.FeesClaimed.selector
            ) {
                claimed = abi.decode(logs[i].data, (uint256));
                ++claims;
            }
        }
        assertEq(refundTo.balance - before, refunded, "event matches payout");
        assertEq(refunded, value - spent + claimed, "refund is unspent eth plus claimed credit");
        assertEq(address(d).balance, 0, "dev buy holds no eth");
        assertEq(escrow.balances(address(d), address(0)), 0, "dev buy holds no credit");
    }

    function _devBuy() internal returns (ArtCoinsUniv4EthDevBuyV2) {
        return new ArtCoinsUniv4EthDevBuyV2(address(this), POOL_MANAGER);
    }

    /// two partial fill launches through one dev buy contract: each recipient
    /// receives its own unspent eth plus the credit its own launch created.
    function test_V2B08_devBuy_refundCreditIsPerLaunch() public onlyFork {
        ArtCoinsUniv4EthDevBuyV2 d = _devBuy();
        (, uint256 refunded1, uint256 claimed1, uint256 claims1) =
            _launchThrough(d, makeAddr("v2b08-launch1-recipient"), -600, 0, 100 ether);
        (, uint256 refunded2, uint256 claimed2, uint256 claims2) =
            _launchThrough(d, makeAddr("v2b08-launch2-recipient"), -600, 0, 100 ether);
        assertEq(claims1, 1, "launch 1 claimed once");
        assertEq(claims2, 1, "launch 2 claimed once");
        assertGt(claimed1, 0);
        assertGt(claimed2, 0);
        // identical launches pay identical amounts, so launch 2 got nothing of launch 1
        assertEq(refunded1, refunded2);
        assertEq(claimed1, claimed2);
    }

    /// a full fill creates no credit, so the launch makes no claim call and
    /// the refund is exactly the unspent eth.
    function test_V2B08_devBuy_fullFillNoClaim() public onlyFork {
        ArtCoinsUniv4EthDevBuyV2 d = _devBuy();
        (uint256 spent, uint256 refunded, uint256 claimed, uint256 claims) =
            _launchThrough(d, makeAddr("v2b08-full-recipient"), FULL_LO, FULL_HI, 1 ether);
        assertEq(claims, 0);
        assertEq(claimed, 0);
        assertEq(refunded, 1 ether - spent);
    }

    /// a credit sitting in the escrow when a launch runs is claimed in full by
    /// that launch and paid to its refund recipient, leaving nothing behind.
    function test_V2B08_devBuy_seededCreditClaimedInFull() public onlyFork {
        ArtCoinsUniv4EthDevBuyV2 d = _devBuy();
        escrow.addDepositor(address(this), false);
        escrow.storeFeesNative{value: 1 ether}(address(d));
        (, uint256 refunded, uint256 claimed,) =
            _launchThrough(d, makeAddr("v2b08-seeded-recipient"), -600, 0, 100 ether);
        assertGt(claimed, 1 ether, "seeded credit plus the launch's own");
        assertGt(refunded, 1 ether);
    }

    /// a failed claim reverts the launch.
    function test_V2B08_devBuy_claimFailureRevertsLaunch() public onlyFork {
        ArtCoinsUniv4EthDevBuyV2 d = _devBuy();
        vm.mockCallRevert(
            address(escrow), abi.encodeWithSelector(IArtCoinsFeeEscrowV2.claimTo.selector), "claim"
        );
        ArtCoinsTokenV2 tk = _newToken(false, bountyEoa, address(hook));
        PoolKey memory k = hook.initializePool(_params(_defaults(bountyEoa), address(tk)));
        _modify(k, -600, 0, int256(LIQ), 0);
        vm.expectRevert();
        _devBuyCall(d, k, address(tk), 100 ether, makeAddr("v2b08-buyer"), makeAddr("v2b08-r"));
    }

    /// during the claim, eth from any sender other than the escrow reverts.
    function test_V2B08_devBuy_nonEscrowSenderDuringClaimReverts() public onlyFork {
        ArtCoinsUniv4EthDevBuyV2 d = _devBuy();
        V2BPoker poker = new V2BPoker();
        vm.deal(address(poker), 1 ether);
        V2BPokingEscrow fake = new V2BPokingEscrow(poker);
        IArtCoinsHookV2.HookGlobals memory g = hook.globals();
        g.feeEscrow = address(fake);
        vm.mockCall(
            address(hook), abi.encodeWithSelector(IArtCoinsHookV2.globals.selector), abi.encode(g)
        );
        ArtCoinsTokenV2 tk = _newToken(false, bountyEoa, address(hook));
        PoolKey memory k = hook.initializePool(_params(_defaults(bountyEoa), address(tk)));
        _modify(k, -600, 0, int256(LIQ), 0);
        vm.expectRevert(IArtCoinsUniv4EthDevBuyV2.UnexpectedEth.selector);
        _devBuyCall(d, k, address(tk), 100 ether, makeAddr("v2b08-buyer"), makeAddr("v2b08-r"));
    }

    function test_V2B08_devBuy_thirdPartyCannotClaim() public onlyFork {
        ArtCoinsUniv4EthDevBuyV2 d = _devBuy();
        _launchThrough(d, makeAddr("v2b08-refund4"), -600, 0, 100 ether); // opts the dev buy into selfClaimOnly
        assertTrue(escrow.selfClaimOnly(address(d)));
        escrow.addDepositor(address(this), false);
        escrow.storeFeesNative{value: 1 ether}(address(d));
        vm.prank(griefer);
        vm.expectRevert(IArtCoinsFeeEscrowV2.Unauthorized.selector);
        escrow.claim(address(d), address(0));
    }

    function test_V2B08_devBuy_directEthReverts() public onlyFork {
        ArtCoinsUniv4EthDevBuyV2 d = _devBuy();
        (bool ok,) = address(d).call{value: 1 wei}("");
        assertFalse(ok);
    }
}
