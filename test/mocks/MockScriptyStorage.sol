// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IScriptyStorageV2} from "../../src/interfaces/IScripty.sol";

/// @notice Test-only ScriptyStorageV2 stand-in. Lets a script preload `name → bytes`
///         entries via `set(...)` and then exposes them through the canonical
///         `getContent(name, "")` selector that both LiquidityLayerOnchainRenderer
///         and the real ScriptyBuilderV2 (when handling tagType 2) call into.
contract MockScriptyStorage is IScriptyStorageV2 {
    mapping(bytes32 => bytes) internal _byName;

    function set(string calldata name, bytes calldata content) external {
        _byName[keccak256(bytes(name))] = content;
    }

    function getContent(string calldata name, bytes calldata) external view returns (bytes memory) {
        return _byName[keccak256(bytes(name))];
    }

    function createContent(string calldata name, bytes calldata details) external {
        _byName[keccak256(bytes(name))] = details;
    }

    function addChunkToContent(string calldata name, bytes calldata chunk) external {
        _byName[keccak256(bytes(name))] = bytes.concat(_byName[keccak256(bytes(name))], chunk);
    }
}
