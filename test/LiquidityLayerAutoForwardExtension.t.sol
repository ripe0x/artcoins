// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {
    LiquidityLayerAutoForwardExtension
} from "../src/extensions/LiquidityLayerAutoForwardExtension.sol";
import {IArtCoinsPoolExtension} from "../src/hooks/interfaces/IArtCoinsPoolExtension.sol";
import {IArtCoinsFeeLocker} from "../src/interfaces/IArtCoinsFeeLocker.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

// ─── Test doubles ─────────────────────────────────────────────────────

contract MintBurnToken is ERC20, ERC20Burnable {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Minimal BurnRouter stub — only `processBurnLayer` is called by the
/// extension. Burns its LAYER balance via the token's `burn` and tracks
/// counts so tests can assert.
contract MockBurnRouter {
    address public immutable token;
    uint256 public processBurnLayerCalls;
    bool public revertProcessBurnLayer;

    constructor(address token_) {
        token = token_;
    }

    function setRevertProcessBurnLayer(bool b) external {
        revertProcessBurnLayer = b;
    }

    function processBurnLayer() external returns (uint256 burned) {
        if (revertProcessBurnLayer) revert("burn layer reverted");
        processBurnLayerCalls++;
        burned = MintBurnToken(token).balanceOf(address(this));
        require(burned > 0, "no layer");
        ERC20Burnable(token).burn(burned);
    }
}

/// Minimal PFC stub — `processFees(token)` zeros the contract's balance for
/// that token, simulating the 60/40 split being executed.
contract MockProtocolFeeController {
    uint256 public processFeesCalls;
    address public lastTokenProcessed;
    bool public revertProcessFees;

    function setRevertProcessFees(bool b) external {
        revertProcessFees = b;
    }

    function processFees(address tokenToProcess) external {
        if (revertProcessFees) revert("processFees reverted");
        processFeesCalls++;
        lastTokenProcessed = tokenToProcess;
        // Drain — anyone can hold whatever, simulate distribution by sending
        // to address(0xdEaD) so `balanceOf` reads zero next time.
        uint256 bal = MintBurnToken(tokenToProcess).balanceOf(address(this));
        if (bal > 0) {
            ERC20(tokenToProcess).transfer(address(0xdEaD), bal);
        }
    }
}

/// Minimal FeeLocker stub — tracks per-(owner, token) pots; `claim` zeroes
/// the pot. Tests pre-populate via `seed`.
contract MockFeeLocker is IArtCoinsFeeLocker {
    mapping(address => mapping(address => uint256)) internal _pots;
    uint256 public claimCalls;
    address public lastClaimOwner;
    address public lastClaimToken;
    bool public revertClaim;

    function setRevertClaim(bool b) external {
        revertClaim = b;
    }

    function seed(address owner, address tokenAddr, uint256 amount) external {
        _pots[owner][tokenAddr] = amount;
    }

    function availableFees(address owner, address tokenAddr) external view returns (uint256) {
        return _pots[owner][tokenAddr];
    }

    function claim(address owner, address tokenAddr) external {
        if (revertClaim) revert("claim reverted");
        claimCalls++;
        lastClaimOwner = owner;
        lastClaimToken = tokenAddr;
        _pots[owner][tokenAddr] = 0;
    }

    // Unused interface methods.
    function storeFees(address, address, uint256) external override {}
    function addDepositor(address) external override {}

    function supportsInterface(bytes4) external pure override returns (bool) {
        return false;
    }
}

// ─── Test ─────────────────────────────────────────────────────────────

contract LiquidityLayerAutoForwardExtensionTest is Test {
    using PoolIdLibrary for PoolKey;

    LiquidityLayerAutoForwardExtension internal ext;
    MintBurnToken internal layer;
    MintBurnToken internal weth;
    MockBurnRouter internal burnRouter;
    MockProtocolFeeController internal pfc;
    MockFeeLocker internal feeLocker;

    address internal hook = makeAddr("hook");
    address internal owner = makeAddr("owner");
    address internal locker = makeAddr("locker");

    PoolKey internal key;
    PoolId internal pid;
    bool internal artCoinIsToken0;

    function setUp() public {
        // Deploy tokens with deterministic ordering: layer < weth so
        // currency0 = layer (matches mainnet LAYER pool layout). Just keep
        // deploying LAYER until address(layer) < address(weth).
        weth = new MintBurnToken("WETH", "WETH");
        layer = new MintBurnToken("LAYER", "LAYER");
        // Bump nonce until ordering is right. Bounded so we don't loop forever.
        for (uint256 i = 0; i < 64; i++) {
            if (uint160(address(layer)) < uint160(address(weth))) break;
            layer = new MintBurnToken("LAYER", "LAYER");
        }
        require(uint160(address(layer)) < uint160(address(weth)), "ordering");

        burnRouter = new MockBurnRouter(address(layer));
        pfc = new MockProtocolFeeController();
        feeLocker = new MockFeeLocker();

        ext = new LiquidityLayerAutoForwardExtension(
            hook, locker, address(feeLocker), address(pfc), address(burnRouter), owner
        );

        key = PoolKey({
            currency0: Currency.wrap(address(layer)),
            currency1: Currency.wrap(address(weth)),
            fee: 0x800000,
            tickSpacing: 200,
            hooks: IHooks(address(0))
        });
        pid = key.toId();
        artCoinIsToken0 = true;

        // Seed init via the hook so `tokenForPool[pid]` is populated.
        vm.prank(hook);
        ext.initializePreLockerSetup(key, artCoinIsToken0, "");
    }

    // ── helpers ────────────────────────────────────────────────────────

    /// Drives a single afterSwap from the bound hook caller. `zeroForOne`:
    ///   true (sell LAYER → WETH, fee in LAYER), false (buy LAYER, fee in WETH).
    function _swap(bool zeroForOne) internal {
        IPoolManager.SwapParams memory p = IPoolManager.SwapParams({
            zeroForOne: zeroForOne, amountSpecified: -1 ether, sqrtPriceLimitX96: 0
        });
        BalanceDelta d = toBalanceDelta(0, 0);
        vm.prank(hook);
        ext.afterSwap(key, p, d, artCoinIsToken0, "");
    }

    // ── auth ──────────────────────────────────────────────────────────

    function test_afterSwap_revertsWhenNotHook() public {
        IPoolManager.SwapParams memory p =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0});
        vm.expectRevert(IArtCoinsPoolExtension.OnlyHook.selector);
        ext.afterSwap(key, p, toBalanceDelta(0, 0), true, "");
    }

    function test_initializePreLockerSetup_revertsWhenNotHook() public {
        vm.expectRevert(IArtCoinsPoolExtension.OnlyHook.selector);
        ext.initializePreLockerSetup(key, true, "");
    }

    // ── counter ───────────────────────────────────────────────────────

    function test_counter_incrementsOnEverySwap_regardlessOfPipelineState() public {
        // Pipeline is empty → no stage fires. Counter must still advance.
        _swap(false); // buy
        _swap(false); // buy
        _swap(true); // sell
        (uint128 buys, uint128 sells) = ext.counts(pid);
        assertEq(buys, 2, "buys");
        assertEq(sells, 1, "sells");
        assertEq(ext.totalTrades(pid), 3, "total");
        assertEq(ext.tokenForPool(pid), address(layer), "token map");
    }

    function test_counter_bitPackedHistory_isCorrect() public {
        _swap(false); // index 0: buy → bit set
        _swap(true); // index 1: sell → bit clear
        _swap(false); // index 2: buy → bit set
        assertTrue(ext.isBuyAt(pid, 0));
        assertFalse(ext.isBuyAt(pid, 1));
        assertTrue(ext.isBuyAt(pid, 2));
    }

    // ── stage 4: processBurnLayer ─────────────────────────────────────

    function test_stage4_firesWhenBurnRouterHasLayer() public {
        layer.mint(address(burnRouter), 1_000_000 ether);
        _swap(true);
        assertEq(burnRouter.processBurnLayerCalls(), 1, "stage4 fired");
        assertEq(layer.balanceOf(address(burnRouter)), 0, "burned");
    }

    function test_stage4_skippedWhenBurnRouterEmpty() public {
        _swap(true);
        assertEq(burnRouter.processBurnLayerCalls(), 0, "no fire");
    }

    function test_stage4_revertCaught_swapStillSucceeds() public {
        layer.mint(address(burnRouter), 1_000_000 ether);
        burnRouter.setRevertProcessBurnLayer(true);
        _swap(true); // must not revert the swap
        // Stage 4 didn't actually burn; counter still advanced.
        assertEq(layer.balanceOf(address(burnRouter)), 1_000_000 ether);
        (uint128 b, uint128 s) = ext.counts(pid);
        assertEq(b + s, 1, "counter advanced");
    }

    // ── stage 3: PFC.processFees ──────────────────────────────────────

    function test_stage3_firesOnPfcWeth() public {
        weth.mint(address(pfc), 0.05 ether);
        _swap(true);
        assertEq(pfc.processFeesCalls(), 1, "fired");
        assertEq(pfc.lastTokenProcessed(), address(weth), "weth path");
    }

    function test_stage3_firesOnPfcLayer() public {
        layer.mint(address(pfc), 200_000 ether);
        _swap(true);
        assertEq(pfc.processFeesCalls(), 1, "fired");
        assertEq(pfc.lastTokenProcessed(), address(layer), "layer path");
    }

    function test_stage3_skippedBelowThreshold() public {
        weth.mint(address(pfc), 0.005 ether); // below 0.01
        layer.mint(address(pfc), 50_000 ether); // below 100k
        _swap(true);
        assertEq(pfc.processFeesCalls(), 0, "skipped");
    }

    function test_stage3_wethPreferredOverLayerWhenBothQualify() public {
        weth.mint(address(pfc), 1 ether);
        layer.mint(address(pfc), 1_000_000 ether);
        _swap(true);
        assertEq(pfc.processFeesCalls(), 1, "only one stage per swap");
        assertEq(pfc.lastTokenProcessed(), address(weth), "weth first");
    }

    // ── stage 2: FeeLocker.claim ──────────────────────────────────────

    function test_stage2_firesBurnRouterWethSlotFirst() public {
        feeLocker.seed(address(burnRouter), address(weth), 0.05 ether);
        _swap(true);
        assertEq(feeLocker.claimCalls(), 1);
        assertEq(feeLocker.lastClaimOwner(), address(burnRouter));
        assertEq(feeLocker.lastClaimToken(), address(weth));
    }

    function test_stage2_firesBurnRouterLayerSlotIfNoWeth() public {
        feeLocker.seed(address(burnRouter), address(layer), 200_000 ether);
        _swap(true);
        assertEq(feeLocker.claimCalls(), 1);
        assertEq(feeLocker.lastClaimToken(), address(layer));
    }

    function test_stage2_firesPfcSlotsAfterBurnRouterSlots() public {
        feeLocker.seed(address(pfc), address(weth), 0.05 ether);
        _swap(true);
        assertEq(feeLocker.claimCalls(), 1);
        assertEq(feeLocker.lastClaimOwner(), address(pfc));
    }

    function test_stage2_skippedBelowThreshold() public {
        feeLocker.seed(address(burnRouter), address(weth), 0.005 ether);
        feeLocker.seed(address(pfc), address(layer), 50_000 ether);
        _swap(true);
        assertEq(feeLocker.claimCalls(), 0);
    }

    // ── priority order: stage 4 before 3 before 2 ─────────────────────

    function test_priority_stage4BeatsStage3() public {
        layer.mint(address(burnRouter), 1000 ether); // Stage 4 ready
        weth.mint(address(pfc), 1 ether); // Stage 3 ready
        _swap(true);
        assertEq(burnRouter.processBurnLayerCalls(), 1, "stage4 fired");
        assertEq(pfc.processFeesCalls(), 0, "stage3 deferred");
    }

    function test_priority_stage3BeatsStage2() public {
        weth.mint(address(pfc), 1 ether); // Stage 3 ready
        feeLocker.seed(address(burnRouter), address(weth), 1 ether); // Stage 2 ready
        _swap(true);
        assertEq(pfc.processFeesCalls(), 1, "stage3 fired");
        assertEq(feeLocker.claimCalls(), 0, "stage2 deferred");
    }

    function test_oneStagePerSwap_evenWithFullPipeline() public {
        layer.mint(address(burnRouter), 1000 ether);
        weth.mint(address(pfc), 1 ether);
        feeLocker.seed(address(burnRouter), address(weth), 1 ether);
        _swap(true);
        // Exactly one of the three stages fired.
        uint256 fires =
            burnRouter.processBurnLayerCalls() + pfc.processFeesCalls() + feeLocker.claimCalls();
        assertEq(fires, 1, "single stage per swap");
    }

    function test_pipelineDrains_oneSwapAtATime() public {
        // All three stages have work. Each swap drains the highest-priority.
        layer.mint(address(burnRouter), 1000 ether);
        weth.mint(address(pfc), 1 ether);
        feeLocker.seed(address(burnRouter), address(weth), 1 ether);

        _swap(true); // drains stage 4 (BurnRouter LAYER)
        _swap(true); // drains stage 3 (PFC WETH)
        _swap(true); // drains stage 2 (FeeLocker pot)
        _swap(true); // nothing left → no-op

        assertEq(burnRouter.processBurnLayerCalls(), 1);
        assertEq(pfc.processFeesCalls(), 1);
        assertEq(feeLocker.claimCalls(), 1);
    }

    // ── threshold setter ──────────────────────────────────────────────

    function test_setThresholds_onlyOwner() public {
        vm.expectRevert(); // OZ Ownable revert
        ext.setThresholds(0, 0, 0, 0);
    }

    function test_setThresholds_takesEffect() public {
        vm.prank(owner);
        ext.setThresholds(0.5 ether, 1_000_000 ether, 0.5 ether, 1_000_000 ether);

        // 0.05 WETH used to qualify; now it's below threshold.
        weth.mint(address(pfc), 0.05 ether);
        _swap(true);
        assertEq(pfc.processFeesCalls(), 0, "below new threshold");
    }

    // ── seedCounters ──────────────────────────────────────────────────

    function test_seedCounters_importsTotals() public {
        vm.prank(owner);
        ext.seedCounters(pid, 100, 50);
        (uint128 b, uint128 s) = ext.counts(pid);
        assertEq(b, 100);
        assertEq(s, 50);
    }

    function test_seedCounters_failsIfAlreadySeeded() public {
        vm.prank(owner);
        ext.seedCounters(pid, 100, 50);
        vm.prank(owner);
        vm.expectRevert();
        ext.seedCounters(pid, 1, 1);
    }

    function test_seedCounters_onlyOwner() public {
        vm.expectRevert();
        ext.seedCounters(pid, 1, 1);
    }

    // ── seedHistory ───────────────────────────────────────────────────

    function test_seedHistory_backfillsBitPackedChunks() public {
        // Seed: 3 buys, 1 sell. Trades in order: buy, sell, buy, buy.
        // Bit layout (LSB = trade 0): 0b1101 = 0xd
        vm.prank(owner);
        ext.seedCounters(pid, 3, 1);

        uint256[] memory chunks = new uint256[](1);
        chunks[0] = 0xd; // bits 0,2,3 set; bit 1 clear
        vm.prank(owner);
        ext.seedHistory(pid, chunks);

        assertTrue(ext.isBuyAt(pid, 0));
        assertFalse(ext.isBuyAt(pid, 1));
        assertTrue(ext.isBuyAt(pid, 2));
        assertTrue(ext.isBuyAt(pid, 3));
        assertEq(ext.totalTrades(pid), 4);
    }

    function test_seedHistory_multiChunk() public {
        // 257 trades → ceil(257/256) = 2 chunks.
        vm.prank(owner);
        ext.seedCounters(pid, 257, 0);
        uint256[] memory chunks = new uint256[](2);
        chunks[0] = type(uint256).max; // all buys in chunk 0
        chunks[1] = 1; // bit 0 of chunk 1 → trade 256 is buy
        vm.prank(owner);
        ext.seedHistory(pid, chunks);
        assertTrue(ext.isBuyAt(pid, 0));
        assertTrue(ext.isBuyAt(pid, 255));
        assertTrue(ext.isBuyAt(pid, 256));
    }

    function test_seedHistory_revertsBeforeSeedCounters() public {
        uint256[] memory chunks = new uint256[](1);
        chunks[0] = 1;
        vm.prank(owner);
        vm.expectRevert(bytes("seed counters first"));
        ext.seedHistory(pid, chunks);
    }

    function test_seedHistory_revertsOnChunkCountMismatch() public {
        vm.prank(owner);
        ext.seedCounters(pid, 5, 0); // expects 1 chunk
        uint256[] memory chunks = new uint256[](2); // wrong count
        vm.prank(owner);
        vm.expectRevert(bytes("chunk count mismatch"));
        ext.seedHistory(pid, chunks);
    }

    function test_seedHistory_revertsOnReSeed() public {
        vm.prank(owner);
        ext.seedCounters(pid, 1, 0);
        uint256[] memory chunks = new uint256[](1);
        chunks[0] = 1;
        vm.prank(owner);
        ext.seedHistory(pid, chunks);
        vm.prank(owner);
        vm.expectRevert(bytes("chunk already seeded"));
        ext.seedHistory(pid, chunks);
    }

    function test_seedHistory_onlyOwner() public {
        vm.expectRevert();
        uint256[] memory chunks = new uint256[](0);
        ext.seedHistory(pid, chunks);
    }

    function test_seedHistory_thenLiveSwap_appendsCorrectly() public {
        vm.prank(owner);
        ext.seedCounters(pid, 1, 1);
        uint256[] memory chunks = new uint256[](1);
        chunks[0] = 0x1; // trade 0 = buy, trade 1 = sell
        vm.prank(owner);
        ext.seedHistory(pid, chunks);

        _swap(false); // buy → trade index 2
        _swap(true); // sell → trade index 3

        (uint128 b, uint128 s) = ext.counts(pid);
        assertEq(b, 2);
        assertEq(s, 2);
        assertTrue(ext.isBuyAt(pid, 0));
        assertFalse(ext.isBuyAt(pid, 1));
        assertTrue(ext.isBuyAt(pid, 2));
        assertFalse(ext.isBuyAt(pid, 3));
    }

    // ── interface ─────────────────────────────────────────────────────

    function test_supportsInterface() public view {
        assertTrue(ext.supportsInterface(type(IArtCoinsPoolExtension).interfaceId));
        assertFalse(ext.supportsInterface(0x12345678));
    }
}
