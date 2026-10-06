// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// test only stand ins for the v2 hook suite.

import {Constants} from "../../../src/Constants.sol";
import {IArtCoinsPoolExtension} from "../../../src/hooks/interfaces/IArtCoinsPoolExtension.sol";
import {IReferralPayoutForHook} from "../../../src/v2/interfaces/IReferralPayoutForHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// answers constantsHash() with a chosen value (locker stand in, or a mismatched module).
contract HV2ConstantsStub {
    bytes32 public immutable constantsHash;

    constructor(bytes32 h) {
        constantsHash = h;
    }
}

/// a module that lies: reports an active skim above MAX_SKIM_BPS forever and a
/// window that never ends.
contract HV2LyingModule {
    address public immutable hook;
    uint24 public reported;

    constructor(address hook_, uint24 reported_) {
        hook = hook_;
        reported = reported_;
    }

    function constantsHash() external pure returns (bytes32) {
        return Constants.hash();
    }

    function initialize(PoolId, bytes calldata) external {}

    function currentSkimBps(PoolId) external view returns (uint24, bool) {
        return (reported, true);
    }

    function windowEnd(PoolId) external pure returns (uint40) {
        return type(uint40).max;
    }
}

/// a module whose reads revert.
contract HV2RevertingModule {
    function constantsHash() external pure returns (bytes32) {
        return Constants.hash();
    }

    function initialize(PoolId, bytes calldata) external {}

    function currentSkimBps(PoolId) external pure returns (uint24, bool) {
        revert("no");
    }

    function windowEnd(PoolId) external pure returns (uint40) {
        revert("no");
    }
}

/// accepts eth, counts streamForward calls.
contract HV2StreamRecipient {
    uint256 public streams;

    receive() external payable {}

    function streamForward() external returns (uint256) {
        streams++;
        return 0;
    }
}

/// empty payable fallback: answers every selector with success and no data
/// (a Safe with no fallback handler looks like this). no withdraw.
contract HV2EmptyFallback {
    fallback() external payable {}
}

/// answers any call with data with 100kb of returndata (fits under the stream
/// gas cap, so the call succeeds and the blob is offered to the caller);
/// accepts plain eth. `bombs` counts successful bomb calls.
contract HV2ReturnBomb {
    uint256 public bombs;

    receive() external payable {}

    fallback() external payable {
        bombs++;
        assembly {
            return(0, 100000)
        }
    }
}

/// burns all gas it is given, on every path.
contract HV2GasBurner {
    receive() external payable {
        while (true) {}
    }

    fallback() external payable {
        while (true) {}
    }
}

/// rejects eth; streamForward reverts too.
contract HV2Rejecter {
    receive() external payable {
        revert("no eth");
    }

    function streamForward() external pure returns (uint256) {
        revert("no");
    }
}

contract HV2ReferralPayout is IReferralPayoutForHook {
    mapping(address => uint256) public credited;

    function notify(address referrer) external payable override {
        credited[referrer] += msg.value;
    }
}

contract HV2RevertingPayout is IReferralPayoutForHook {
    function notify(address) external payable override {
        revert("closed");
    }
}

/// records extension callbacks.
contract HV2Extension is IArtCoinsPoolExtension {
    address public immutable hook;
    uint256 public preSetups;
    uint256 public postSetups;
    uint256 public swaps;
    int128 public lastAmount0;
    bytes public lastData;

    constructor(address hook_) {
        hook = hook_;
    }

    function initializePreLockerSetup(PoolKey calldata, bool, bytes calldata) external {
        require(msg.sender == hook, "only hook");
        preSetups++;
    }

    function initializePostLockerSetup(PoolKey calldata, address, bool) external {
        require(msg.sender == hook, "only hook");
        postSetups++;
    }

    function afterSwap(
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        BalanceDelta delta,
        bool,
        bytes calldata data
    ) external {
        require(msg.sender == hook, "only hook");
        swaps++;
        lastAmount0 = delta.amount0();
        lastData = data;
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }
}

interface IHV2Erc20 {
    function transfer(address to, uint256 amount) external returns (bool);
}

/// liquidity actions inside ONE unlock (H14 / b1 shapes). holds its own eth
/// and coin, settles what it owes, sends any credit to `owner`.
/// modes: 0 add then remove, 1 remove then add, 2 add only, 3 remove only
/// (liq 0 = fee collect).
contract HV2AddRemoveRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    uint8 public constant ADD_REMOVE = 0;
    uint8 public constant REMOVE_ADD = 1;
    uint8 public constant ADD = 2;
    uint8 public constant REMOVE = 3;

    IPoolManager public immutable pm;
    address public immutable owner;
    /// credit sent to `owner` per currency in the last run.
    uint256 public lastTake0;
    uint256 public lastTake1;

    constructor(IPoolManager pm_) {
        pm = pm_;
        owner = msg.sender;
    }

    receive() external payable {}

    function run(PoolKey calldata key, int24 lo, int24 hi, uint256 liq, bytes32 salt, uint8 mode)
        external
    {
        lastTake0 = 0;
        lastTake1 = 0;
        pm.unlock(abi.encode(key, lo, hi, liq, salt, mode));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        require(msg.sender == address(pm), "pm");
        (PoolKey memory key, int24 lo, int24 hi, uint256 liq, bytes32 salt, uint8 mode) =
            abi.decode(raw, (PoolKey, int24, int24, uint256, bytes32, uint8));
        int256 l = int256(liq);
        if (mode == ADD_REMOVE) {
            _modify(key, lo, hi, l, salt);
            _modify(key, lo, hi, -l, salt);
        } else if (mode == REMOVE_ADD) {
            _modify(key, lo, hi, -l, salt);
            _modify(key, lo, hi, l, salt);
        } else if (mode == ADD) {
            _modify(key, lo, hi, l, salt);
        } else {
            _modify(key, lo, hi, -l, salt);
        }
        lastTake0 = _close(key.currency0);
        lastTake1 = _close(key.currency1);
        return "";
    }

    function _modify(PoolKey memory key, int24 lo, int24 hi, int256 l, bytes32 salt) private {
        pm.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: lo, tickUpper: hi, liquidityDelta: l, salt: salt
            }),
            ""
        );
    }

    function _close(Currency c) private returns (uint256 taken) {
        int256 d = pm.currencyDelta(address(this), c);
        if (d < 0) {
            uint256 owe = uint256(-d);
            if (c.isAddressZero()) {
                pm.settle{value: owe}();
            } else {
                pm.sync(c);
                IHV2Erc20(Currency.unwrap(c)).transfer(address(pm), owe);
                pm.settle();
            }
        } else if (d > 0) {
            taken = uint256(d);
            pm.take(c, owner, taken);
        }
    }
}

/// runs several swaps inside ONE unlock, then settles eth from its own
/// balance and takes the net coin credit to `owner`. a step with
/// `amount == 0` sells the router's whole coin credit so far (exact in).
contract HV2SwapSeqRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    struct Step {
        PoolKey key;
        bool zeroForOne;
        int256 amount;
    }

    IPoolManager public immutable pm;
    address public immutable owner;
    uint256 public lastTake1;

    constructor(IPoolManager pm_) {
        pm = pm_;
        owner = msg.sender;
    }

    receive() external payable {}

    function run(Step[] calldata steps) external {
        lastTake1 = 0;
        pm.unlock(abi.encode(steps));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        require(msg.sender == address(pm), "pm");
        Step[] memory steps = abi.decode(raw, (Step[]));
        Currency coin;
        for (uint256 i; i < steps.length; ++i) {
            Step memory st = steps[i];
            coin = st.key.currency1;
            int256 amt = st.amount;
            if (amt == 0) amt = -pm.currencyDelta(address(this), coin);
            pm.swap(
                st.key,
                IPoolManager.SwapParams({
                    zeroForOne: st.zeroForOne,
                    amountSpecified: amt,
                    sqrtPriceLimitX96: st.zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341
                }),
                ""
            );
        }
        int256 d0 = pm.currencyDelta(address(this), Currency.wrap(address(0)));
        if (d0 < 0) pm.settle{value: uint256(-d0)}();
        else if (d0 > 0) pm.take(Currency.wrap(address(0)), address(this), uint256(d0));
        int256 d1 = pm.currencyDelta(address(this), coin);
        require(d1 >= 0, "coin owed");
        if (d1 > 0) {
            lastTake1 = uint256(d1);
            pm.take(coin, owner, uint256(d1));
        }
        return "";
    }
}
