// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArtCoinsFactoryV2} from "../../../src/v2/interfaces/IArtCoinsFactoryV2.sol";

/// @dev Stub factory: only `deploymentInfo`. Unregistered tokens return a zeroed record, like a mapping read.
contract KeeperMockFactory {
    mapping(address => IArtCoinsFactoryV2.DeploymentInfoV2) internal _info;

    function register(address token, address locker) external {
        IArtCoinsFactoryV2.DeploymentInfoV2 storage i = _info[token];
        i.token = token;
        i.locker = locker;
        i.version = 2;
    }

    /// @dev registers a record whose `token` field does not match the key (corrupt or foreign record)
    function registerMismatched(address key, address recordToken, address locker) external {
        _info[key].token = recordToken;
        _info[key].locker = locker;
    }

    function deploymentInfo(address token)
        external
        view
        returns (IArtCoinsFactoryV2.DeploymentInfoV2 memory)
    {
        return _info[token];
    }
}
