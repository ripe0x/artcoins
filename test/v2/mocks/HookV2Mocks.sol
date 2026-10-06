// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// test only stand ins for the v2 hook suite.

import {Constants} from "../../../src/Constants.sol";
import {IReferralPayoutForHook} from "../../../src/v2/interfaces/IReferralPayoutForHook.sol";
import {IArtCoinsPoolExtension} from "../../../src/hooks/interfaces/IArtCoinsPoolExtension.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
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

/// returns a huge returndata blob for any call with data; accepts plain eth.
contract HV2ReturnBomb {
    receive() external payable {}

    fallback() external payable {
        assembly {
            return(0, 1000000)
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
