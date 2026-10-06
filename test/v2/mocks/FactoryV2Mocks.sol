// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// test only stand ins for test/v2/FactoryV2.fork.t.sol.

import {Constants} from "../../../src/Constants.sol";
import {IArtCoinsExtensionV2} from "../../../src/v2/interfaces/IArtCoinsExtensionV2.sol";
import {IArtCoinsFactoryV2} from "../../../src/v2/interfaces/IArtCoinsFactoryV2.sol";
import {IArtCoinsMevSkimV2} from "../../../src/v2/interfaces/IArtCoinsMevSkimV2.sol";
import {IReferralPayoutForHook} from "../../../src/v2/interfaces/IReferralPayoutForHook.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// referral payout with code (the hook requires code at init).
contract FV2Payout is IReferralPayoutForHook {
    function notify(address referrer) external payable {
        (bool ok,) = referrer.call{value: msg.value}("");
        ok;
    }
}

/// launch extension. mode 0 pulls its share, 1 pulls nothing, 2 pulls one wei
/// less, 3 tries to reenter the factory.
contract FV2Extension is IArtCoinsExtensionV2 {
    uint8 public mode;
    bool public broken;
    uint256 public receivedValue;
    uint256 public expectedValue;
    uint256 public receivedSupply;
    uint256 public calls;

    function setMode(uint8 m) external {
        mode = m;
    }

    function setBroken(bool b) external {
        broken = b;
    }

    function receiveTokens(
        IArtCoinsFactoryV2.DeploymentConfigV2 calldata config,
        PoolKey calldata,
        address token,
        uint256 extensionSupply,
        uint256 extensionIndex
    ) external payable {
        calls++;
        receivedValue = msg.value;
        expectedValue = config.extensions[extensionIndex].msgValue;
        if (mode == 0) {
            IERC20(token).transferFrom(msg.sender, address(this), extensionSupply);
            receivedSupply = extensionSupply;
        } else if (mode == 2 && extensionSupply != 0) {
            IERC20(token).transferFrom(msg.sender, address(this), extensionSupply - 1);
        } else if (mode == 3) {
            IArtCoinsFactoryV2(msg.sender).deployToken(config);
        }
    }

    function supportsInterface(bytes4 id) external view returns (bool) {
        require(!broken, "broken");
        return id == type(IArtCoinsExtensionV2).interfaceId || id == type(IERC165).interfaceId;
    }

    function constantsHash() external view returns (bytes32) {
        require(!broken, "broken");
        return Constants.hash();
    }
}

/// a v2 shaped mev module whose erc165 and constants answers can be broken
/// after it is enabled (FT-04).
contract FV2ToggleModule {
    address public immutable hook;
    bool public broken;

    constructor(address hook_) {
        hook = hook_;
    }

    function setBroken(bool b) external {
        broken = b;
    }

    function supportsInterface(bytes4 id) external view returns (bool) {
        require(!broken, "broken");
        return id == type(IArtCoinsMevSkimV2).interfaceId || id == type(IERC165).interfaceId;
    }

    function constantsHash() external view returns (bytes32) {
        require(!broken, "broken");
        return Constants.hash();
    }

    function initialize(PoolId, bytes calldata) external {}
}

/// answers the module interface but a different constants set.
contract FV2WrongHashModule {
    address public immutable hook;

    constructor(address hook_) {
        hook = hook_;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IArtCoinsMevSkimV2).interfaceId || id == type(IERC165).interfaceId;
    }

    function constantsHash() external pure returns (bytes32) {
        return keccak256("other constants");
    }
}

/// right constants, no erc165 (a v1 lp fee module shape, D22).
contract FV2NoErc165Module {
    function constantsHash() external pure returns (bytes32) {
        return Constants.hash();
    }
}

/// answers constantsHash() with a chosen value and poolManager() with a chosen address.
contract FV2HashStub {
    bytes32 public immutable constantsHash;
    address public immutable poolManager;

    constructor(bytes32 h, address pm) {
        constantsHash = h;
        poolManager = pm;
    }
}

/// eth sink that always reverts.
contract FV2RevertingReceiver {
    receive() external payable {
        revert("no eth");
    }
}
