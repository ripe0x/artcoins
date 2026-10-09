// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RunKeeper111} from "../../script/v2/RunKeeper111.s.sol";
import {IArtCoinsFeeLocker} from "../../src/interfaces/IArtCoinsFeeLocker.sol";
import {IArtCoinsLpLocker} from "../../src/interfaces/IArtCoinsLpLocker.sol";
import {IFeeAutoSwapper} from "../../src/interfaces/IFeeAutoSwapper.sol";
import {CollectFlushKeeperV1} from "../../src/legacy/keepers/CollectFlushKeeperV1.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Test, Vm, console2} from "forge-std/Test.sol";

interface ISwapperV1 {
    function endRecipient() external view returns (address);
    function totalKeeperRewards() external view returns (uint256);
    function lastConvertBlock() external view returns (uint256);
    function minBlocksBetweenConverts() external view returns (uint256);
}

interface IEscrowV1 {
    function claim(address feeOwner, address token) external;
}

interface ILockerOwner {
    function owner() external view returns (address);
    function keeperRewardBps() external view returns (uint256);
    function setKeeperRewardBps(uint256) external;
}

/// @notice Fork proofs for `CollectFlushKeeperV1` against the live coin 111 stack.
/// @dev Pinned block 26_130_269 (shared with the v2 harness so the rpc cache is reused). Skips when the
///      rpc is unreachable or `SKIP_FORK_TESTS=true`. Live locker keeperRewardBps is 0, so tests that
///      prove reward forwarding prank the locker owner to set 50 bps (fork only, nothing is broadcast).
contract KeeperV1_111_ForkTest is Test {
    uint256 internal constant FORK_BLOCK = 26_130_269;
    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    // deployments/mainnet.json (current stack)
    address internal constant LOCKER = 0x866ea3Dc2bf7A3e77374619cf50EB697FA766aab;
    address internal constant COIN = 0x61C9d89fe1212F6b55fF888816A151463287B8ae;
    address internal constant SWAPPER = 0xeBD9B74A4c26C6E54e83C84CB247c069eC42A961;
    address internal constant ESCROW = 0x7559689765aE86cBB38e68CD1294830CccB125F2;

    address internal constant CALLER = address(0xBEEF);
    address internal constant GRIEFER = address(0xBAD);

    bool internal onFork;
    CollectFlushKeeperV1 internal keeper;
    PoolSwapTest internal router;
    PoolKey internal key;

    receive() external payable {}

    function setUp() public {
        if (vm.envOr("SKIP_FORK_TESTS", false)) return;
        string memory rpc =
            vm.envOr("MAINNET_RPC_URL", string("https://mainnet.gateway.tenderly.co"));
        try vm.createSelectFork(rpc, vm.envOr("FORK_BLOCK", FORK_BLOCK)) {}
        catch {
            console2.log("fork unavailable: tests skipped");
            return;
        }
        if (block.number == 0 || POOL_MANAGER.code.length == 0) return;
        onFork = true;
        keeper = new CollectFlushKeeperV1(LOCKER, COIN, SWAPPER, ESCROW);
        // the default test contract create addresses carry real mainnet dust; start from a clean keeper
        vm.deal(address(keeper), 0);
        router = new PoolSwapTest(IPoolManager(POOL_MANAGER));
        key = IArtCoinsLpLocker(LOCKER).tokenRewards(COIN).poolKey;
    }

    modifier onlyFork() {
        if (!onFork) vm.skip(true);
        _;
    }

    // ─── helpers ─────────────────────────────────────────────────────────

    /// @dev buy with eth (currency0 is native), then sell the whole bag back: eth side and coin side fees.
    function _makeFees() internal {
        vm.deal(address(this), 3 ether);
        _swap(true, 1 ether, 1 ether);
        uint256 bag = IERC20(COIN).balanceOf(address(this));
        IERC20(COIN).approve(address(router), type(uint256).max);
        _swap(false, bag, 0);
    }

    function _swap(bool zeroForOne, uint256 amountIn, uint256 value) internal {
        router.swap{value: value}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _setLockerReward50() internal {
        vm.prank(ILockerOwner(LOCKER).owner());
        ILockerOwner(LOCKER).setKeeperRewardBps(50);
    }

    function _escrowEth() internal view returns (uint256) {
        return IArtCoinsFeeLocker(ESCROW).availableFees(SWAPPER, address(0));
    }

    // ─── tests ───────────────────────────────────────────────────────────

    function test_liveReadings() public onlyFork {
        assertEq(ILockerOwner(LOCKER).keeperRewardBps(), 0, "live locker reward bps");
        assertEq(ISwapperV1(SWAPPER).minBlocksBetweenConverts(), 50);
        assertEq(ISwapperV1(SWAPPER).endRecipient(), 0x8C72FBc2bB32e76aa54243F76745266a0F92CD01);
        assertEq(address(SWAPPER).balance, 0, "swapper eth at pin");
        assertEq(_escrowEth(), 0, "escrow eth at pin");
        assertEq(IArtCoinsLpLocker(LOCKER).tokenRewards(COIN).rewardRecipients[0], SWAPPER);
        assertEq(Currency.unwrap(key.currency0), address(0), "eth is currency0");
    }

    function test_keeperV1_111_collectFlushConvert_fork() public onlyFork {
        _makeFees();
        _setLockerReward50();
        vm.roll(block.number + 60); // clears minBlocksBetweenConverts (also true at the pin)

        (uint256 hint, uint256 hintCoin, uint256 escrowedBefore, uint256 stranded,) =
            keeper.preview();
        assertGt(hint, 0, "preview sees uncollected eth fees");
        assertGt(hintCoin, 0, "preview sees uncollected coin fees");
        assertEq(stranded, 0);
        uint256 rewardsBefore = ISwapperV1(SWAPPER).totalKeeperRewards();
        uint256 callerBefore = CALLER.balance; // mainnet address, may hold real eth

        vm.expectEmit(true, false, false, false, address(keeper));
        emit CollectFlushKeeperV1.KeeperRun(CALLER, 0, 0, 0);
        uint256 g = gasleft();
        vm.prank(CALLER);
        (uint256 collected, uint256 flushed, uint256 converted) = keeper.run(true, 0);
        console2.log("run(true,0) gas", g - gasleft());
        console2.log("hint", hint);
        console2.log("collected", collected);
        console2.log("flushed", flushed);
        console2.log("converted", converted);

        assertGt(collected, 0, "locker rewards collected");
        assertEq(flushed, escrowedBefore + collected, "flush drains the whole slot");
        assertEq(address(SWAPPER).balance, 0, "swapper eth zero after flush and convert");
        assertEq(_escrowEth(), 0, "escrow eth slot empty");
        assertGt(converted, 0, "convert executed");
        assertEq(ISwapperV1(SWAPPER).lastConvertBlock(), block.number, "convert stamped");
        assertEq(address(keeper).balance, 0, "keeper holds no eth");
        assertEq(IERC20(COIN).balanceOf(address(keeper)), 0, "keeper holds no coin");

        // reward = locker reward (hint - collected) + swapper flush + convert rewards, all to the caller
        uint256 swapperRewards = ISwapperV1(SWAPPER).totalKeeperRewards() - rewardsBefore;
        uint256 lockerReward = hint - collected;
        assertGt(CALLER.balance, callerBefore, "caller got rewards");
        assertApproxEqAbs(
            CALLER.balance - callerBefore, swapperRewards + lockerReward, 200, "caller reward sum"
        );
        // preview after the run: nothing escrowed, nothing stranded
        (,, uint256 e2, uint256 s2,) = keeper.preview();
        assertEq(e2, 0);
        assertEq(s2, 0);
    }

    function test_keeperV1_convertTooEarly_isSwallowed() public onlyFork {
        _makeFees();
        vm.roll(block.number + 60);
        vm.prank(CALLER);
        (, uint256 f1, uint256 c1) = keeper.run(true, 0);
        assertGt(f1, 0);
        assertGt(c1, 0);
        _makeFees(); // more fees in the same block window
        vm.recordLogs();
        vm.prank(CALLER);
        (uint256 col2, uint256 f2, uint256 c2) = keeper.run(true, 0); // same block: convert reverts ConvertTooEarly
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool reported;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(keeper)
                    && logs[i].topics[0] == CollectFlushKeeperV1.ConvertSkipped.selector
            ) {
                reported = true;
                bytes memory reason = abi.decode(logs[i].data, (bytes));
                assertGt(reason.length, 0, "skip reason carries the revert data");
            }
        }
        assertTrue(reported, "convert skip is reported, not silent");
        assertGt(col2, 0);
        assertEq(f2, col2);
        assertEq(c2, 0, "convert skipped inside min blocks, run did not revert");
        assertEq(address(SWAPPER).balance, 0);
        assertEq(address(keeper).balance, 0);
    }

    /// @dev D49: a collect revert for a reason other than gas is a real failure and bubbles.
    function test_keeperV1_collectRevert_bubbles() public onlyFork {
        vm.mockCallRevert(
            LOCKER, abi.encodeCall(IArtCoinsLpLocker.collectRewards, (COIN)), bytes("collect broke")
        );
        vm.prank(CALLER);
        vm.expectRevert(bytes("collect broke"));
        keeper.run(true, 0);
    }

    /// @dev reviewer finding: a gas limit picked by estimateGas must never land on a path that skips convert.
    ///      Sweeps limits across the whole range: every run either reverts or converts, never succeeds with
    ///      converted == 0 while coin fees wait.
    function test_keeperV1_lowGas_neverSilentlySkips() public onlyFork {
        _makeFees();
        vm.roll(block.number + 60);
        uint256 snap = vm.snapshotState();
        uint256 reverted;
        uint256 succeeded;
        for (uint256 limit = 1_300_000; limit >= 300_000; limit -= 25_000) {
            (bool ok, bytes memory ret) = address(keeper).call{gas: limit}(
                abi.encodeCall(CollectFlushKeeperV1.run, (true, 0))
            );
            if (ok) {
                (,, uint256 converted) = abi.decode(ret, (uint256, uint256, uint256));
                assertGt(converted, 0, "succeeded without converting");
                assertEq(address(SWAPPER).balance, 0);
                ++succeeded;
            } else {
                ++reverted;
            }
            vm.revertToState(snap);
            snap = vm.snapshotState();
        }
        console2.log("sweep succeeded", succeeded);
        console2.log("sweep reverted", reverted);
        assertGt(succeeded, 0);
        assertGt(reverted, 0);
    }

    /// @dev the runner script's quote (simulate, minus slippage) converts at the default 100 bps, and a
    ///      minOut above the simulated output makes convert skip (swallowed) instead of reverting the run.
    function test_keeperV1_scriptQuote_convertsAtDefaultSlippage() public onlyFork {
        _makeFees();
        vm.roll(block.number + 60);
        RunKeeper111 script = new RunKeeper111();
        uint256 minOut = script.quoteMinOut(keeper, 100);
        assertGt(minOut, 0);
        uint256 snap = vm.snapshotState();
        vm.prank(CALLER);
        (,, uint256 converted) = keeper.run(true, minOut);
        assertGe(converted, minOut);
        assertGt(converted, 0);
        vm.revertToState(snap);
        vm.prank(CALLER);
        (uint256 collected,, uint256 skipped) = keeper.run(true, type(uint256).max);
        assertGt(collected, 0, "collect and flush still ran");
        assertEq(skipped, 0, "impossible minOut: convert skipped, run succeeded");
    }

    function test_keeperV1_nothingToFlush_noRevert() public onlyFork {
        vm.roll(block.number + 60);
        vm.prank(CALLER);
        keeper.run(true, 0); // drain whatever the live pin holds
        uint256 callerBefore = CALLER.balance;
        vm.prank(CALLER);
        (uint256 collected, uint256 flushed, uint256 converted) = keeper.run(true, 0);
        assertEq(collected, 0);
        assertEq(flushed, 0);
        assertEq(converted, 0);
        assertEq(CALLER.balance, callerBefore, "no reward when nothing happened");
        assertEq(address(keeper).balance, 0);
        assertEq(IERC20(COIN).balanceOf(address(keeper)), 0);
    }

    /// @dev documents the live exposure: `escrow.claim(swapper, 0)` is permissionless, the escrow pays the
    ///      swapper by plain eth transfer, and v1 `flushPaired` only reads `escrow.availableFees`, which is
    ///      now 0 (NothingToFlush). The swapper has no sweep, convert only forwards the swap output, so the
    ///      eth stays. The keeper cannot fix this; atomic collect then flush only closes the window for
    ///      honest flows, not for a griefer who calls collect and claim himself.
    function test_bug_swapperV1_thirdPartyClaim_strandsEth() public onlyFork {
        _makeFees();
        vm.roll(block.number + 60);
        // anyone may collect; the locker deposits the swapper's share at the escrow
        IArtCoinsLpLocker(LOCKER).collectRewards(COIN);
        uint256 escrowed = _escrowEth();
        assertGt(escrowed, 0, "fees sit at the escrow under the swapper slot");
        // griefer pushes it into the swapper, bypassing the swapper's bookkeeping
        vm.prank(GRIEFER);
        IEscrowV1(ESCROW).claim(SWAPPER, address(0));
        assertEq(address(SWAPPER).balance, escrowed, "eth now sits in the swapper");
        assertEq(_escrowEth(), 0);

        vm.prank(CALLER);
        (, uint256 flushed, uint256 converted) = keeper.run(true, 0);
        assertEq(flushed, 0, "flushPaired reverted NothingToFlush, swallowed");
        assertGt(converted, 0, "convert still works on the coin side");
        assertEq(address(SWAPPER).balance, escrowed, "stranded eth untouched by flush and convert");
        assertEq(address(keeper).balance, 0);

        (,,, uint256 swapperPaired,) = keeper.preview();
        assertEq(swapperPaired, escrowed, "preview exposes the stranded amount");
    }
}
