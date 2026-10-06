// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// package i1: test only stand ins for the v2 integration suite. credits engine
// style treasuries (one per receive shape), a currencyDelta settling router, a
// v3 lp and trader, and a lying anti sniper module.

import {Constants} from "../../../../src/Constants.sol";
import {IArtCoinsFeeEscrowV2} from "../../../../src/v2/interfaces/IArtCoinsFeeEscrowV2.sol";
import {IArtCoinsMevSkimV2} from "../../../../src/v2/interfaces/IArtCoinsMevSkimV2.sol";
import {IConstantsBound} from "../../../../src/v2/interfaces/IConstantsBound.sol";

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface II1Erc20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

// ══════════════════════════════════════════════════════════════════════════
// treasury mocks (CREDITS-ENGINE-INTERFACE.md section 2 shapes)
// ══════════════════════════════════════════════════════════════════════════

/// option a: an empty payable receive, nothing else. a stipend push lands.
contract I1EmptyTreasury {
    receive() external payable {}
}

/// an empty payable fallback (a Safe without a fallback handler looks like
/// this): answers every selector, accepts eth. a stipend push lands.
contract I1FallbackTreasury {
    fallback() external payable {}
}

/// a payable fallback that reverts on every call, plain eth included. a push
/// fails (escrow); `claim` reverts too; the treasury pulls with `claimTo`.
contract I1RevertingTreasury {
    fallback() external payable {
        revert("treasury: closed");
    }

    /// fee owner pull to a payable target (CREDITS section 2, row 3).
    function pull(IArtCoinsFeeEscrowV2 escrow, address payable target) external {
        escrow.claimTo(address(this), address(0), target);
    }
}

/// burns all gas it is given on every path.
contract I1GasBurnerTreasury {
    receive() external payable {
        while (true) {}
    }

    fallback() external payable {
        while (true) {}
    }
}

/// tries to act on the PoolManager from `receive` while the swapper's unlock is
/// open (review v2h-01). mode 0: take 1 wei eth (leave a debt). mode 1: take
/// 1e18 coin (spend the buyer's exemption). under the 2,300 stipend both run
/// out of gas, so the push fails and the leg lands in escrow. with full gas
/// (an escrow claim, PoolManager locked) the take reverts `ManagerLocked`, so
/// it only counts attempts it survives.
contract I1TakeTreasury {
    IPoolManager public immutable pm;
    uint8 public immutable mode;
    address public coin;
    uint256 public tookOk;

    constructor(IPoolManager pm_, uint8 mode_) {
        pm = pm_;
        mode = mode_;
    }

    function setCoin(address c) external {
        coin = c;
    }

    receive() external payable {
        if (mode == 0) pm.take(Currency.wrap(address(0)), address(this), 1);
        else pm.take(Currency.wrap(coin), address(this), 1e18);
        tookOk++;
    }
}

/// logic behind `I1ProxyTreasury`: does accounting in the proxy's storage.
contract I1TreasuryLogic {
    uint256 public received; // slot 0, shared with the proxy
    uint256 public pushes; // slot 1

    receive() external payable {
        received += msg.value;
        pushes++;
    }
}

/// a proxy treasury: `receive` reads the implementation from the eip-1967
/// slot (a cold sload, 2,100 gas) and delegatecalls it. under the 2,300
/// stipend that cannot complete, so a hook push lands in escrow. a claim
/// (full gas) runs the logic.
contract I1ProxyTreasury {
    uint256 public received; // slot 0, written by the logic via delegatecall
    uint256 public pushes; // slot 1
    bytes32 internal constant IMPL_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    constructor(address logic) {
        assembly ("memory-safe") {
            sstore(IMPL_SLOT, logic)
        }
    }

    receive() external payable {
        _delegate();
    }

    fallback() external payable {
        _delegate();
    }

    function _delegate() private {
        assembly {
            let impl := sload(IMPL_SLOT)
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}

/// a payable receive that does accounting (two sstores, far above 2,300 gas).
/// a hook push fails (escrow); `escrow.claim(treasury, 0)` by anyone runs it
/// with the claimer's full gas.
contract I1AccountingTreasury {
    uint256 public received;
    uint256 public pushes;

    receive() external payable {
        received += msg.value;
        pushes++;
    }
}

/// v1 style treasury: implements `IPreSwapStream.streamForward()` (the live
/// 111 bounty recipient shape) and accepts eth. v2 never calls it (D41).
contract I1StreamTreasury {
    uint256 public streams;

    receive() external payable {}

    function streamForward() external returns (uint256) {
        streams++;
        return 0;
    }
}

// ══════════════════════════════════════════════════════════════════════════
// routers and actors
// ══════════════════════════════════════════════════════════════════════════

/// one swap inside one unlock, settled from `currencyDelta` the way V4Router
/// does (not from the returned BalanceDelta): eth debt from its own balance,
/// coin debt by transfer from its own balance, credits taken to itself.
/// records the returned delta and the transient deltas before settlement.
contract I1DeltaRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable pm;
    int256 public lastReturned0;
    int256 public lastReturned1;
    int256 public lastNet0;
    int256 public lastNet1;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    receive() external payable {}

    function swap(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amount,
        uint160 limit,
        bytes calldata hd
    ) external {
        pm.unlock(abi.encode(key, zeroForOne, amount, limit, hd));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        require(msg.sender == address(pm), "pm");
        (PoolKey memory key, bool zeroForOne, int256 amount, uint160 limit, bytes memory hd) =
            abi.decode(raw, (PoolKey, bool, int256, uint160, bytes));
        if (limit == 0) {
            limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        }
        BalanceDelta d = pm.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne, amountSpecified: amount, sqrtPriceLimitX96: limit
            }),
            hd
        );
        lastReturned0 = d.amount0();
        lastReturned1 = d.amount1();
        int256 d0 = pm.currencyDelta(address(this), key.currency0);
        int256 d1 = pm.currencyDelta(address(this), key.currency1);
        lastNet0 = d0;
        lastNet1 = d1;
        if (d0 < 0) pm.settle{value: uint256(-d0)}();
        else if (d0 > 0) pm.take(key.currency0, address(this), uint256(d0));
        if (d1 < 0) {
            pm.sync(key.currency1);
            II1Erc20(Currency.unwrap(key.currency1)).transfer(address(pm), uint256(-d1));
            pm.settle();
        } else if (d1 > 0) {
            pm.take(key.currency1, address(this), uint256(d1));
        }
        return "";
    }
}

interface II1V3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function initialize(uint160 sqrtPriceX96) external;
    function mint(address recipient, int24 lo, int24 hi, uint128 amount, bytes calldata data)
        external
        returns (uint256, uint256);
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 limit,
        bytes calldata data
    ) external returns (int256, int256);
}

/// v3 lp and trader: pays mint and swap callbacks from its own balance.
contract I1V3Actor {
    function mint(address pool, uint128 liq) external {
        II1V3Pool(pool).mint(address(this), -887_220, 887_220, liq, "");
    }

    function swap(address pool, address to, bool zeroForOne, int256 amt, uint160 lim)
        external
        returns (int256, int256)
    {
        return II1V3Pool(pool).swap(to, zeroForOne, amt, lim, "");
    }

    function uniswapV3MintCallback(uint256 a0, uint256 a1, bytes calldata) external {
        _pay(a0, a1);
    }

    function uniswapV3SwapCallback(int256 d0, int256 d1, bytes calldata) external {
        _pay(d0 > 0 ? uint256(d0) : 0, d1 > 0 ? uint256(d1) : 0);
    }

    function _pay(uint256 a0, uint256 a1) internal {
        II1V3Pool p = II1V3Pool(msg.sender);
        if (a0 > 0) II1Erc20(p.token0()).transfer(msg.sender, a0);
        if (a1 > 0) II1Erc20(p.token1()).transfer(msg.sender, a1);
    }
}

/// an anti sniper module the factory accepts (erc165, constants hash, bound
/// to the hook) that lies: reports an active skim forever and a window that
/// never ends. the hook must treat it as expired at createdAt + MAX_MEV_WINDOW.
contract I1LyingMevModule is IArtCoinsMevSkimV2 {
    address public immutable hook;
    uint24 public immutable reported;

    constructor(address hook_, uint24 reported_) {
        hook = hook_;
        reported = reported_;
    }

    function initialize(PoolId, bytes calldata) external view {
        if (msg.sender != hook) revert NotHook();
    }

    function currentSkimBps(PoolId) external view returns (uint24, bool) {
        return (reported, true);
    }

    function windowEnd(PoolId) external pure returns (uint40) {
        return type(uint40).max;
    }

    function constantsHash() external pure returns (bytes32) {
        return Constants.hash();
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IArtCoinsMevSkimV2).interfaceId || id == type(IERC165).interfaceId
            || id == type(IConstantsBound).interfaceId;
    }
}
