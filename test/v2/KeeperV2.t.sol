// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsKeeperV2} from "../../src/v2/interfaces/IArtCoinsKeeperV2.sol";
import {IFeeAutoSwapperV2} from "../../src/v2/interfaces/IFeeAutoSwapperV2.sol";
import {ArtCoinsKeeperV2} from "../../src/v2/keepers/ArtCoinsKeeperV2.sol";
import {KeeperMockCoin} from "./mocks/KeeperMockCoin.sol";
import {KeeperMockFactory} from "./mocks/KeeperMockFactory.sol";
import {KeeperMockLocker} from "./mocks/KeeperMockLocker.sol";
import {
    KeeperMockGasBurnerRecipient,
    KeeperMockNotSwapper,
    KeeperMockPlainRecipient,
    KeeperMockSwapper,
    KeeperMockWideReturnRecipient
} from "./mocks/KeeperMockSwapper.sol";
import {Test} from "forge-std/Test.sol";

/// @dev A caller that cannot take eth.
contract EthRejecter {
    function run(ArtCoinsKeeperV2 k, address token) external {
        k.collectAndForward(token, true, 0);
    }
}

/// @dev A caller that can take eth and records the coin it received.
contract Runner {
    receive() external payable {}

    function run(ArtCoinsKeeperV2 k, address token, bool doConvert, uint256 minOut) external {
        k.collectAndForward(token, doConvert, minOut);
    }
}

contract KeeperV2Test is Test {
    ArtCoinsKeeperV2 internal keeper;
    KeeperMockFactory internal factory;
    KeeperMockLocker internal locker;
    KeeperMockCoin internal coin;
    KeeperMockSwapper internal swapper;

    address internal caller = address(0xBEEF);

    event KeeperRun(
        address indexed caller,
        address indexed token,
        uint256 nativeForwarded,
        uint256 coinForwarded
    );
    event SwapperServiced(
        address indexed token, address indexed swapper, uint256 flushed, uint256 converted
    );
    event ConvertSkipped(address indexed token, address indexed swapper, bytes reason);
    event FlushSkipped(address indexed token, address indexed swapper, bytes reason);

    function setUp() public {
        factory = new KeeperMockFactory();
        coin = new KeeperMockCoin();
        locker = new KeeperMockLocker(coin);
        swapper = new KeeperMockSwapper();
        keeper = new ArtCoinsKeeperV2(address(factory));

        factory.register(address(coin), address(locker));
        _setRecipients(address(swapper));

        vm.deal(address(locker), 10 ether);
        vm.deal(address(swapper), 10 ether);
        vm.deal(caller, 0);
        vm.txGasPrice(0);
    }

    // ── helpers ───────────────────────────────────────────────────────────

    function _setRecipients(address a) internal {
        address[] memory r = new address[](1);
        r[0] = a;
        locker.setRecipients(r);
    }

    function _setRecipients(address a, address b) internal {
        address[] memory r = new address[](2);
        r[0] = a;
        r[1] = b;
        locker.setRecipients(r);
    }

    function _run(bool doConvert, uint256 minOut) internal {
        vm.prank(caller);
        keeper.collectAndForward(address(coin), doConvert, minOut);
    }

    function _assertKeeperEmpty() internal view {
        assertEq(address(keeper).balance, 0, "keeper eth");
        assertEq(coin.balanceOf(address(keeper)), 0, "keeper coin");
    }

    // ── construction ──────────────────────────────────────────────────────

    function test_keeperV2_factoryImmutable() public view {
        assertEq(keeper.factory(), address(factory));
    }

    function test_keeperV2_zeroFactoryReverts() public {
        vm.expectRevert(ArtCoinsKeeperV2.ZeroAddress.selector);
        new ArtCoinsKeeperV2(address(0));
    }

    // ── happy path ────────────────────────────────────────────────────────

    function test_keeperV2_collectAndForward_swapperRecipient() public {
        locker.setRewards(0.3 ether, 500e18);
        swapper.set(0.1 ether, 0.2 ether, 1 ether, 4 ether);

        vm.expectEmit(address(keeper));
        emit SwapperServiced(address(coin), address(swapper), 1 ether, 4 ether);
        vm.expectEmit(address(keeper));
        emit KeeperRun(caller, address(coin), 0.6 ether, 500e18);
        _run(true, 123);

        assertEq(locker.collectCalls(), 1, "collected");
        assertEq(swapper.flushCalls(), 1, "flushed");
        assertEq(swapper.convertCalls(), 1, "converted");
        assertEq(swapper.lastMinOut(), 123, "minOut passed through");
        assertEq(caller.balance, 0.6 ether, "caller eth is locker + flush + convert rewards");
        assertEq(coin.balanceOf(caller), 500e18, "caller coin");
        _assertKeeperEmpty();
    }

    function test_keeperV2_noRewards_stillRuns() public {
        _run(true, 0);
        assertEq(locker.collectCalls(), 1);
        assertEq(swapper.flushCalls(), 1);
        assertEq(caller.balance, 0);
        _assertKeeperEmpty();
    }

    function test_keeperV2_callerContractReceivesRewards() public {
        Runner runner = new Runner();
        locker.setRewards(0.3 ether, 7e18);
        swapper.set(0.1 ether, 0, 0, 0);
        runner.run(keeper, address(coin), false, 0);
        assertEq(address(runner).balance, 0.4 ether);
        assertEq(coin.balanceOf(address(runner)), 7e18);
        _assertKeeperEmpty();
    }

    // ── not an art coin ───────────────────────────────────────────────────

    function test_keeperV2_nonArtCoin_reverts() public {
        address stranger = address(0xDEAD1);
        vm.expectRevert(abi.encodeWithSelector(IArtCoinsKeeperV2.NotArtCoin.selector, stranger));
        keeper.collectAndForward(stranger, true, 0);
        assertEq(locker.collectCalls(), 0);
    }

    function test_keeperV2_mismatchedRecord_reverts() public {
        address key = address(0xDEAD2);
        factory.registerMismatched(key, address(coin), address(locker));
        vm.expectRevert(abi.encodeWithSelector(IArtCoinsKeeperV2.NotArtCoin.selector, key));
        keeper.collectAndForward(key, true, 0);
    }

    function test_keeperV2_zeroLockerRecord_reverts() public {
        address t = address(0xDEAD3);
        factory.register(t, address(0));
        vm.expectRevert(abi.encodeWithSelector(IArtCoinsKeeperV2.NotArtCoin.selector, t));
        keeper.collectAndForward(t, true, 0);
    }

    function test_keeperV2_preview_nonArtCoin_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IArtCoinsKeeperV2.NotArtCoin.selector, address(1)));
        keeper.preview(address(1));
    }

    // ── recipients ────────────────────────────────────────────────────────

    function test_keeperV2_recipientWithoutErc165_isSkipped() public {
        KeeperMockPlainRecipient plain = new KeeperMockPlainRecipient();
        KeeperMockNotSwapper notSwapper = new KeeperMockNotSwapper();
        KeeperMockGasBurnerRecipient burner = new KeeperMockGasBurnerRecipient();
        KeeperMockWideReturnRecipient wide = new KeeperMockWideReturnRecipient();
        address eoa = address(0xE0A);

        address[] memory r = new address[](6);
        r[0] = address(plain);
        r[1] = address(notSwapper);
        r[2] = eoa;
        r[3] = address(burner);
        r[4] = address(wide);
        r[5] = address(swapper);
        locker.setRecipients(r);
        swapper.set(0.1 ether, 0, 0, 0);

        _run(true, 0);

        assertEq(notSwapper.otherCalls(), 0, "non swapper only probed");
        assertEq(swapper.flushCalls(), 1, "swapper after the skipped ones is still serviced");
        assertEq(swapper.convertCalls(), 1);
        assertEq(caller.balance, 0.1 ether);
        _assertKeeperEmpty();
    }

    function test_keeperV2_onlyNonSwapperRecipients_collectsOnly() public {
        _setRecipients(address(new KeeperMockPlainRecipient()));
        locker.setRewards(0.2 ether, 0);
        _run(true, 0);
        assertEq(locker.collectCalls(), 1);
        assertEq(caller.balance, 0.2 ether);
        _assertKeeperEmpty();
    }

    function test_keeperV2_duplicateRecipient_servicedOnce() public {
        _setRecipients(address(swapper), address(swapper));
        _run(true, 0);
        assertEq(swapper.flushCalls(), 1);
        assertEq(swapper.convertCalls(), 1);
    }

    function test_keeperV2_twoSwappers_bothServiced() public {
        KeeperMockSwapper second = new KeeperMockSwapper();
        vm.deal(address(second), 1 ether);
        _setRecipients(address(swapper), address(second));
        swapper.set(0.01 ether, 0.02 ether, 0, 0);
        second.set(0.03 ether, 0.04 ether, 0, 0);
        _run(true, 9);
        assertEq(swapper.flushCalls() + second.flushCalls(), 2);
        assertEq(swapper.convertCalls() + second.convertCalls(), 2);
        assertEq(second.lastMinOut(), 9);
        assertEq(caller.balance, 0.1 ether);
        _assertKeeperEmpty();
    }

    // ── convert only when asked ───────────────────────────────────────────

    function test_keeperV2_convert_notCalledWhenDoConvertFalse() public {
        swapper.set(0.1 ether, 0.2 ether, 1 ether, 4 ether);
        _run(false, 55);
        assertEq(swapper.flushCalls(), 1, "flush always runs");
        assertEq(swapper.convertCalls(), 0, "convert must not run");
        assertEq(caller.balance, 0.1 ether, "no convert reward");
    }

    function test_keeperV2_convert_calledWhenDoConvertTrue() public {
        swapper.set(0.1 ether, 0.2 ether, 1 ether, 4 ether);
        _run(true, 55);
        assertEq(swapper.convertCalls(), 1);
        assertEq(swapper.lastMinOut(), 55);
        assertEq(caller.balance, 0.3 ether);
    }

    // ── real failures: collect bubbles, flush and convert are reported ────

    function test_keeperV2_collectRevert_bubbles() public {
        locker.setFailCollect(true);
        swapper.set(0.1 ether, 0, 0, 0);
        vm.prank(caller);
        vm.expectRevert(bytes("nothing to collect"));
        keeper.collectAndForward(address(coin), false, 0);
        assertEq(swapper.flushCalls(), 0, "nothing ran after a collect failure");
        assertEq(caller.balance, 0);
        _assertKeeperEmpty();
    }

    function test_keeperV2_flushAndConvertRevert_areReported_notSilent() public {
        swapper.setReverts(true, true);
        locker.setRewards(0.3 ether, 0);
        vm.expectEmit(address(keeper));
        emit FlushSkipped(
            address(coin),
            address(swapper),
            abi.encodeWithSelector(IFeeAutoSwapperV2.NothingToFlush.selector)
        );
        vm.expectEmit(address(keeper));
        emit ConvertSkipped(
            address(coin),
            address(swapper),
            abi.encodeWithSelector(IFeeAutoSwapperV2.ConvertTooEarly.selector, block.number + 50)
        );
        vm.expectEmit(address(keeper));
        emit SwapperServiced(address(coin), address(swapper), 0, 0);
        _run(true, 0);
        assertEq(swapper.flushCalls(), 0);
        assertEq(swapper.convertCalls(), 0);
        assertEq(caller.balance, 0.3 ether, "locker reward still forwarded");
        _assertKeeperEmpty();
    }

    function test_keeperV2_convertTooEarly_isReported_flushRewardKept() public {
        swapper.set(0.1 ether, 0.2 ether, 0, 0);
        swapper.setReverts(false, true);
        vm.expectEmit(address(keeper));
        emit ConvertSkipped(
            address(coin),
            address(swapper),
            abi.encodeWithSelector(IFeeAutoSwapperV2.ConvertTooEarly.selector, block.number + 50)
        );
        _run(true, 0);
        assertEq(swapper.flushCalls(), 1);
        assertEq(caller.balance, 0.1 ether);
    }

    // ── floors, not caps (D49) ────────────────────────────────────────────

    /// @dev collect (1.3m), flush (400k) and convert (700k) all run past the old per step caps (950k, 200k,
    ///      450k) when the tx supplies the gas.
    function test_keeperV2_stepsBeyondOldCaps_stillRun() public {
        locker.setBurn(1_300_000);
        swapper.setBurn(400_000, 700_000);
        locker.setRewards(0.3 ether, 0);
        swapper.set(0.1 ether, 0.2 ether, 0, 0);
        vm.prank(caller);
        keeper.collectAndForward{gas: 3_500_000}(address(coin), true, 0);
        assertEq(locker.collectCalls(), 1);
        assertEq(swapper.flushCalls(), 1);
        assertEq(swapper.convertCalls(), 1);
        assertEq(caller.balance, 0.6 ether);
        _assertKeeperEmpty();
    }

    /// @dev a step that really runs out of gas (floor passed, then starved) reports InsufficientGas, it does not
    ///      bubble an empty revert or skip.
    function test_keeperV2_outOfGasInsideCollect_reportsInsufficientGas() public {
        locker.setBurn(50_000_000);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(ArtCoinsKeeperV2.InsufficientGas.selector, uint8(1)));
        keeper.collectAndForward{gas: 3_000_000}(address(coin), true, 0);
    }

    // ── gas floor: revert, never silently skip ────────────────────────────

    function test_keeperV2_lowGas_collectStep_reverts() public {
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(ArtCoinsKeeperV2.InsufficientGas.selector, uint8(1)));
        keeper.collectAndForward{gas: 400_000}(address(coin), true, 0);
        assertEq(locker.collectCalls(), 0);
    }

    function test_keeperV2_lowGas_flushStep_reverts() public {
        locker.setBurn(850_000); // leaves too little for the flush floor
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(ArtCoinsKeeperV2.InsufficientGas.selector, uint8(2)));
        keeper.collectAndForward{gas: 1_100_000}(address(coin), true, 0);
    }

    function test_keeperV2_lowGas_convertStep_reverts() public {
        // collect and flush burn what the convert floor (about 477k) needs, but leave the flush floor intact
        locker.setBurn(600_000);
        swapper.setBurn(100_000, 0);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(ArtCoinsKeeperV2.InsufficientGas.selector, uint8(3)));
        keeper.collectAndForward{gas: 1_100_000}(address(coin), true, 0);
        assertEq(locker.collectCalls(), 0, "reverted run left state");
    }

    function test_keeperV2_lowGas_convertSkippedFloorNotAppliedWhenNotConverting() public {
        // same gas as the convert step test, but doConvert false: no convert floor, run completes
        locker.setBurn(600_000);
        swapper.setBurn(100_000, 0);
        swapper.set(0.1 ether, 0, 0, 0);
        vm.prank(caller);
        keeper.collectAndForward{gas: 1_100_000}(address(coin), false, 0);
        assertEq(swapper.flushCalls(), 1);
        assertEq(caller.balance, 0.1 ether);
    }

    function test_keeperV2_lowGas_probeStep_reverts() public {
        // locker burn leaves less than the probe floor, so the probe must revert instead of calling the
        // recipient with a starved stipend and calling it "not a swapper"
        locker.setBurn(900_000);
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(keeper).call{gas: 985_000}(
            abi.encodeCall(IArtCoinsKeeperV2.collectAndForward, (address(coin), true, 0))
        );
        assertFalse(ok);
        bytes4 sel;
        assembly {
            sel := mload(add(ret, 0x20))
        }
        assertEq(sel, ArtCoinsKeeperV2.InsufficientGas.selector);
        assertEq(swapper.flushCalls(), 0);
    }

    /// @dev Sweep gas limits. Each run either reverts `InsufficientGas` or has done every step. No limit may
    ///      complete with a step skipped, and no limit may fail any other way.
    function test_keeperV2_gasSweep_neverSilentlySkips() public {
        locker.setBurn(300_000);
        swapper.setBurn(100_000, 100_000);
        uint256 completed;
        uint256 insufficient;
        for (uint256 g = 100_000; g <= 2_500_000; g += 25_000) {
            locker.resetCalls();
            swapper.resetCalls();
            locker.setRewards(0.01 ether, 1e18);
            vm.prank(caller);
            (bool ok, bytes memory ret) = address(keeper).call{gas: g}(
                abi.encodeCall(IArtCoinsKeeperV2.collectAndForward, (address(coin), true, 77))
            );
            if (ok) {
                ++completed;
                assertEq(locker.collectCalls(), 1, "collect skipped");
                assertEq(swapper.flushCalls(), 1, "flush skipped");
                assertEq(swapper.convertCalls(), 1, "convert skipped");
                assertEq(swapper.lastMinOut(), 77);
            } else {
                ++insufficient;
                assertEq(ret.length, 36, "failure is not a custom error with one arg");
                bytes4 sel;
                assembly {
                    sel := mload(add(ret, 0x20))
                }
                assertEq(
                    sel, ArtCoinsKeeperV2.InsufficientGas.selector, "failed for another reason"
                );
                assertEq(locker.collectCalls(), 0, "reverted run left state");
            }
            assertEq(address(keeper).balance, 0);
        }
        assertGt(completed, 0, "no gas limit completed");
        assertGt(insufficient, 0, "no gas limit hit the floor");
    }

    // ── never holds funds ─────────────────────────────────────────────────

    function test_keeperV2_holdsNothingAfterRun_evenWithDonation() public {
        vm.deal(address(keeper), 1 ether); // donation or earlier stray eth goes to the caller
        coin.mint(address(keeper), 11e18);
        locker.setRewards(0.2 ether, 5e18);
        swapper.set(0.1 ether, 0.1 ether, 0, 0);
        _run(true, 0);
        assertEq(caller.balance, 1.4 ether);
        assertEq(coin.balanceOf(caller), 16e18);
        _assertKeeperEmpty();
    }

    function test_keeperV2_callerRejectingEth_reverts() public {
        EthRejecter rej = new EthRejecter();
        locker.setRewards(0.2 ether, 0);
        vm.expectRevert(IArtCoinsKeeperV2.EthTransferFailed.selector);
        rej.run(keeper, address(coin));
        assertEq(address(keeper).balance, 0, "revert undid the receipt");
    }

    function test_keeperV2_coinTransferFailure_reverts_notHeld() public {
        locker.setRewards(0, 5e18);
        coin.setFailTransfers(true);
        vm.prank(caller);
        vm.expectRevert();
        keeper.collectAndForward(address(coin), false, 0);
    }

    function test_keeperV2_reentrantRecipient_cannotRedirectRewards() public {
        locker.setRewards(0.3 ether, 0);
        swapper.set(0.1 ether, 0, 0, 0);
        swapper.setReenter(address(keeper), address(coin));
        _run(false, 0);
        assertFalse(swapper.reenterSucceeded(), "reentry succeeded");
        assertGt(swapper.reenterRevertData().length, 0, "reentry was not rejected");
        assertEq(caller.balance, 0.4 ether, "caller got everything");
        assertEq(address(swapper).balance, 10 ether - 0.1 ether);
        _assertKeeperEmpty();
    }

    // ── preview ───────────────────────────────────────────────────────────

    function test_keeperV2_preview_sumsSwapperState() public {
        KeeperMockSwapper second = new KeeperMockSwapper();
        _setRecipients(address(swapper), address(second));
        swapper.setAccrued(1 ether, 100e18, 500);
        second.setAccrued(2 ether, 50e18, 400);
        (uint256 n, uint256 paired, uint256 art, uint256 next) = keeper.preview(address(coin));
        assertEq(n, 2);
        assertEq(paired, 3 ether);
        assertEq(art, 150e18);
        assertEq(next, 400);
    }

    function test_keeperV2_preview_ignoresNonSwappers() public {
        address[] memory r = new address[](3);
        r[0] = address(new KeeperMockPlainRecipient());
        r[1] = address(0xE0A);
        r[2] = address(swapper);
        locker.setRecipients(r);
        swapper.setAccrued(1 ether, 2e18, 7);
        (uint256 n, uint256 paired, uint256 art, uint256 next) = keeper.preview(address(coin));
        assertEq(n, 1);
        assertEq(paired, 1 ether);
        assertEq(art, 2e18);
        assertEq(next, 7);
    }

    function test_keeperV2_noOwner() public view {
        (bool ok,) = address(keeper).staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
    }
}
