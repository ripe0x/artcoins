// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {P1Base, P1GasBurner, P1Rejector, P1Sink, P1Stray} from "./p1/P1Base.sol";

import {Constants} from "../../src/Constants.sol";
import {FeeAutoSwapperV2} from "../../src/v2/FeeAutoSwapperV2.sol";
import {IArtCoinsFeeEscrowV2} from "../../src/v2/interfaces/IArtCoinsFeeEscrowV2.sol";
import {IConstantsBound} from "../../src/v2/interfaces/IConstantsBound.sol";
import {IFeeAutoSwapperV2} from "../../src/v2/interfaces/IFeeAutoSwapperV2.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title  FeeAutoSwapperV2ForkTest
/// @notice DESIGN b5 swapper half, review LF-02, LF-07, LF-08.
/// Run: /tmp/claude-0/forge.sh test --match-path test/v2/FeeAutoSwapperV2.fork.t.sol -vv
contract FeeAutoSwapperV2ForkTest is P1Base {
    FeeAutoSwapperV2 internal swapper;
    P1Sink internal end;
    address internal keeper = makeAddr("keeper");
    address internal attacker = makeAddr("attacker");

    uint256 internal constant STEP = 1e24; // 1e6 coin ~ 1 eth at the start price

    function setUp() public {
        _setUpChain();
        end = new P1Sink();
        swapper = _deploy(address(end), address(coin));
        escrow.addDepositor(address(this), false);
        escrow.addDepositor(address(swapper), false);
        coin.approve(address(escrow), type(uint256).max);
        vm.deal(attacker, 10 ether);
    }

    function _deploy(address endRecipient, address artCoin) internal returns (FeeAutoSwapperV2) {
        return new FeeAutoSwapperV2(
            FeeAutoSwapperV2.Config({
                owner: address(this),
                poolManager: address(pm),
                feeEscrow: address(escrow),
                hook: address(0),
                poolFee: POOL_FEE,
                tickSpacing: TICK_SPACING,
                endRecipient: endRecipient,
                artCoin: artCoin,
                maxSlippageBps: 500,
                minBlocksBetweenConverts: 50,
                maxStepIn: STEP
            })
        );
    }

    function _reward(uint256 amount) internal pure returns (uint256 r) {
        r = amount * Constants.KEEPER_REWARD_BPS / Constants.BPS;
        if (r > Constants.KEEPER_REWARD_CAP) r = Constants.KEEPER_REWARD_CAP;
    }

    // ── b5 / LF-02 ────────────────────────────────────────────────────────

    /// @notice The v1 stranding path: eth credited to the swapper in the escrow
    ///         gets pushed in by a third party, after which v1's ledger based
    ///         flush saw nothing. v2: the third party claim is refused
    ///         (selfClaimOnly, set in the constructor), and eth that reaches the
    ///         swapper by any other path is forwarded by the balance based flush.
    function test_swapperV2_thirdPartyEscrowClaim_thenFlush_forwardsAll() public {
        escrow.storeFeesNative{value: 1 ether}(address(swapper));
        assertTrue(escrow.selfClaimOnly(address(swapper)), "self claim only set");

        vm.prank(attacker);
        vm.expectRevert(IArtCoinsFeeEscrowV2.Unauthorized.selector);
        escrow.claim(address(swapper), address(0));

        // eth pushed in outside the ledger (a claim on another escrow, a direct send)
        vm.prank(attacker);
        (bool ok,) = address(swapper).call{value: 0.5 ether}("");
        assertTrue(ok);

        uint256 endBefore = address(end).balance;
        vm.prank(keeper);
        uint256 out = swapper.flushPaired();

        uint256 reward = _reward(1.5 ether);
        assertEq(out, 1.5 ether, "gross");
        assertEq(keeper.balance, reward, "keeper reward");
        assertEq(address(end).balance - endBefore, 1.5 ether - reward, "recipient gets the rest");
        assertEq(address(swapper).balance, 0, "invariant: no eth left");
        assertEq(escrow.balances(address(swapper), address(0)), 0, "escrow drained");
    }

    function test_swapperV2_flush_nothingEscrowed_forwardsBalance() public {
        vm.prank(attacker);
        (bool ok,) = address(swapper).call{value: 0.3 ether}("");
        assertTrue(ok);
        assertEq(swapper.accruedPaired(), 0.3 ether);

        vm.prank(keeper);
        assertEq(swapper.flushPaired(), 0.3 ether);
        assertEq(address(end).balance, 0.3 ether - _reward(0.3 ether));
        assertEq(address(swapper).balance, 0);
    }

    function test_swapperV2_flush_empty_reverts() public {
        vm.expectRevert(IFeeAutoSwapperV2.NothingToFlush.selector);
        swapper.flushPaired();
    }

    function test_swapperV2_flush_worksBeforeSetup() public {
        FeeAutoSwapperV2 s = _deploy(address(end), address(0));
        (bool ok,) = address(s).call{value: 1 ether}("");
        assertTrue(ok);
        s.flushPaired();
        assertEq(address(s).balance, 0);
    }

    function test_swapperV2_accruedPaired_heldPlusEscrowed() public {
        escrow.storeFeesNative{value: 2 ether}(address(swapper));
        (bool ok,) = address(swapper).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(swapper.accruedPaired(), 3 ether);
    }

    // ── LF-08: payout failures never brick ───────────────────────────────

    function test_swapperV2_revertingEndRecipient_fallsBackToEscrow() public {
        address rej = address(new P1Rejector());
        FeeAutoSwapperV2 s = _deploy(rej, address(coin));
        escrow.addDepositor(address(s), false);
        escrow.storeFeesNative{value: 1 ether}(address(s));

        vm.prank(keeper);
        s.flushPaired();
        assertEq(escrow.balances(rej, address(0)), 1 ether - _reward(1 ether), "credited");
        assertEq(address(s).balance, 0, "invariant");
    }

    function test_swapperV2_gasBurningEndRecipient_fallsBackToEscrow() public {
        address burner = address(new P1GasBurner());
        FeeAutoSwapperV2 s = _deploy(burner, address(coin));
        escrow.addDepositor(address(s), false);
        (bool ok,) = address(s).call{value: 1 ether}("");
        assertTrue(ok);

        s.flushPaired{gas: 2_000_000}();
        assertEq(escrow.balances(burner, address(0)), 1 ether - _reward(1 ether));
        assertEq(address(s).balance, 0);
    }

    function test_swapperV2_rejectingKeeper_rewardGoesToRecipient() public {
        address rej = address(new P1Rejector());
        (bool ok,) = address(swapper).call{value: 1 ether}("");
        assertTrue(ok);
        vm.prank(rej);
        swapper.flushPaired();
        assertEq(address(end).balance, 1 ether, "whole balance to recipient");
        assertEq(address(swapper).balance, 0);
    }

    // ── convert ───────────────────────────────────────────────────────────

    function test_swapperV2_convert_claimsEscrowedCoin_andForwardsAll() public {
        escrow.storeFees(address(swapper), address(coin), STEP);
        // held eth is forwarded too
        (bool ok,) = address(swapper).call{value: 0.2 ether}("");
        assertTrue(ok);
        assertEq(swapper.accruedArtCoin(), STEP);

        vm.prank(keeper);
        uint256 out = swapper.convert(0);
        assertGt(out, 0);
        uint256 reward = _reward(out);
        assertEq(keeper.balance, reward, "reward on swap output only");
        assertEq(address(end).balance, out + 0.2 ether - reward, "output plus held eth");
        assertEq(address(swapper).balance, 0, "invariant");
        assertEq(coin.balanceOf(address(swapper)), 0, "step consumed");
        assertEq(escrow.balances(address(swapper), address(coin)), 0);
    }

    function test_swapperV2_convert_honoursMinOut() public {
        coin.transfer(address(swapper), STEP);
        vm.expectPartialRevert(IFeeAutoSwapperV2.InsufficientOutput.selector);
        swapper.convert(100 ether);

        uint256 expectFloor = swapper.floorFor(STEP);
        uint256 out = swapper.convert(expectFloor);
        assertGe(out, expectFloor, "floor view matches enforcement");
    }

    function test_swapperV2_convert_honoursMinBlocks() public {
        coin.transfer(address(swapper), 3 * STEP);
        swapper.convert(0);
        uint256 next = block.number + 50;
        assertEq(swapper.nextConvertibleBlock(), next);

        vm.expectRevert(abi.encodeWithSelector(IFeeAutoSwapperV2.ConvertTooEarly.selector, next));
        swapper.convert(0);

        vm.roll(block.number + 49);
        vm.expectRevert(abi.encodeWithSelector(IFeeAutoSwapperV2.ConvertTooEarly.selector, next));
        swapper.convert(0);

        vm.roll(block.number + 1);
        swapper.convert(0);
    }

    function test_swapperV2_convert_partialFill_respectsSlippageLimit() public {
        swapper.setMaxStepIn(1e27);
        swapper.setMaxSlippageBps(200);
        coin.transfer(address(swapper), 1e27); // ~10x the pool's coin side
        uint160 pre = _spot();
        swapper.convert(0);
        uint160 post = _spot();
        assertLe(_priceMoveBps(pre, post), 200, "move capped");
        assertGt(coin.balanceOf(address(swapper)), 0, "rest waits for next call");
        assertEq(address(swapper).balance, 0, "invariant");
    }

    function test_swapperV2_convert_nothing_reverts() public {
        vm.expectRevert(IFeeAutoSwapperV2.NothingToConvert.selector);
        swapper.convert(0);
    }

    function test_swapperV2_convert_beforeSetup_reverts() public {
        FeeAutoSwapperV2 s = _deploy(address(end), address(0));
        vm.expectRevert(IFeeAutoSwapperV2.NotFinalized.selector);
        s.convert(0);
    }

    function test_swapperV2_unlockCallback_onlyPoolManager() public {
        vm.expectRevert(FeeAutoSwapperV2.NotPoolManager.selector);
        swapper.unlockCallback(abi.encode(uint256(1), uint160(1)));
    }

    // ── rescue ────────────────────────────────────────────────────────────

    function test_swapperV2_rescue_cannotTouchPairedOrArtCoin() public {
        coin.transfer(address(swapper), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IFeeAutoSwapperV2.CannotRescue.selector, address(0)));
        swapper.rescue(address(0), address(this), 1);
        vm.expectRevert(
            abi.encodeWithSelector(IFeeAutoSwapperV2.CannotRescue.selector, address(coin))
        );
        swapper.rescue(address(coin), address(this), 1e18);

        P1Stray stray = new P1Stray();
        stray.transfer(address(swapper), 5e18);
        address to = makeAddr("to");
        swapper.rescue(address(stray), to, 5e18);
        assertEq(stray.balanceOf(to), 5e18);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        swapper.rescue(address(stray), attacker, 0);
    }

    // ── tunables ──────────────────────────────────────────────────────────

    function test_swapperV2_tunables_bounded() public {
        uint256 lo = Constants.SWAPPER_SLIPPAGE_MIN;
        uint256 hi = Constants.SWAPPER_SLIPPAGE_MAX;
        vm.expectRevert(abi.encodeWithSelector(IFeeAutoSwapperV2.OutOfBounds.selector, lo - 1, lo, hi));
        swapper.setMaxSlippageBps(lo - 1);
        vm.expectRevert(abi.encodeWithSelector(IFeeAutoSwapperV2.OutOfBounds.selector, hi + 1, lo, hi));
        swapper.setMaxSlippageBps(hi + 1);
        swapper.setMaxSlippageBps(lo);
        swapper.setMaxSlippageBps(hi);
        assertEq(swapper.maxSlippageBps(), hi);

        lo = Constants.SWAPPER_MIN_BLOCKS_MIN;
        hi = Constants.SWAPPER_MIN_BLOCKS_MAX;
        vm.expectRevert(abi.encodeWithSelector(IFeeAutoSwapperV2.OutOfBounds.selector, lo - 1, lo, hi));
        swapper.setMinBlocksBetweenConverts(lo - 1);
        vm.expectRevert(abi.encodeWithSelector(IFeeAutoSwapperV2.OutOfBounds.selector, hi + 1, lo, hi));
        swapper.setMinBlocksBetweenConverts(hi + 1);
        swapper.setMinBlocksBetweenConverts(hi);
        assertEq(swapper.minBlocksBetweenConverts(), hi);

        hi = uint256(uint128(type(int128).max));
        vm.expectRevert(abi.encodeWithSelector(IFeeAutoSwapperV2.OutOfBounds.selector, 0, 1, hi));
        swapper.setMaxStepIn(0);
        vm.expectRevert(abi.encodeWithSelector(IFeeAutoSwapperV2.OutOfBounds.selector, hi + 1, 1, hi));
        swapper.setMaxStepIn(hi + 1);
        swapper.setMaxStepIn(hi);
        assertEq(swapper.maxStepIn(), hi);

        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        swapper.setMaxSlippageBps(100);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        swapper.setMinBlocksBetweenConverts(10);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        swapper.setMaxStepIn(1);
        vm.stopPrank();
    }

    function test_swapperV2_constructor_rejectsOutOfBounds() public {
        FeeAutoSwapperV2.Config memory c = FeeAutoSwapperV2.Config({
            owner: address(this),
            poolManager: address(pm),
            feeEscrow: address(escrow),
            hook: address(0),
            poolFee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            endRecipient: address(escrow),
            artCoin: address(coin),
            maxSlippageBps: 500,
            minBlocksBetweenConverts: 50,
            maxStepIn: STEP
        });
        vm.expectRevert(IFeeAutoSwapperV2.InvalidEndRecipient.selector);
        new FeeAutoSwapperV2(c);
        c.endRecipient = address(end);
        c.maxSlippageBps = 1001;
        vm.expectPartialRevert(IFeeAutoSwapperV2.OutOfBounds.selector);
        new FeeAutoSwapperV2(c);
    }

    // ── setup and erc165 ──────────────────────────────────────────────────

    function test_swapperV2_setup_onceByDeployer() public {
        FeeAutoSwapperV2 s = _deploy(address(end), address(0));
        assertFalse(s.setupFinalized());
        vm.prank(attacker);
        vm.expectRevert(IFeeAutoSwapperV2.NotDeployer.selector);
        s.setup(address(coin));
        s.setup(address(coin));
        assertTrue(s.setupFinalized());
        assertEq(s.artCoin(), address(coin));
        assertEq(keccak256(abi.encode(s.poolKey())), keccak256(abi.encode(key)), "pool key");
        vm.expectRevert(IFeeAutoSwapperV2.AlreadyFinalized.selector);
        s.setup(address(coin));
        // ctor bound swapper is final
        assertTrue(swapper.setupFinalized());
        vm.expectRevert(IFeeAutoSwapperV2.AlreadyFinalized.selector);
        swapper.setup(address(coin));
    }

    function test_swapperV2_supportsInterface() public view {
        assertTrue(swapper.supportsInterface(type(IFeeAutoSwapperV2).interfaceId));
        assertTrue(swapper.supportsInterface(type(IERC165).interfaceId));
        assertTrue(swapper.supportsInterface(type(IConstantsBound).interfaceId));
        assertFalse(swapper.supportsInterface(0xffffffff));
        assertEq(swapper.constantsHash(), Constants.hash());
    }
}
