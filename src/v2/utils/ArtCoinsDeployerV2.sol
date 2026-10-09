// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Constants} from "../../Constants.sol";
import {ArtCoinsTokenV2} from "../ArtCoinsTokenV2.sol";
import {IArtCoinsFactoryV2} from "../interfaces/IArtCoinsFactoryV2.sol";
import {IConstantsBound} from "../interfaces/IConstantsBound.sol";

/// @title  ArtCoinsDeployerV2
/// @notice CREATE2 deployer for `ArtCoinsTokenV2`, bound to one factory.
/// @dev    Binding: `factory` is a constructor immutable. Either the factory
///         deploys this contract in its own constructor
///         (`new ArtCoinsDeployerV2(address(this))`) or the deploy script
///         predicts the factory address (CREATE nonce or CREATE2) and deploys
///         this first. The deployer is ownerless and `factory` is fixed at construction.
///
///         Address binding: the factory passes
///         `salt = keccak256(abi.encode(sender, configHash))`. The initcode
///         also carries every constructor argument, so the token address is a
///         function of (this deployer, hence the factory; sender; full config).
///         A front runner copying a config from the mempool gets a different
///         address and cannot block or capture the victim's launch.
///
///         `deploy` and `predict` hash the same initcode bytes, so a
///         prediction always matches the deploy.
contract ArtCoinsDeployerV2 is IConstantsBound {
    /// @notice The only caller allowed to deploy, and the token's `launcher`.
    address public immutable factory;

    /// @notice A token was deployed.
    /// @param token Deployed token address.
    /// @param salt CREATE2 salt used.
    event TokenDeployed(address indexed token, bytes32 indexed salt);

    /// @notice The caller of `deploy` is not the factory.
    error NotFactory();
    /// @notice `launcher` passed to `deploy` is not the factory.
    error LauncherMismatch();
    /// @notice The factory address given at construction is zero.
    error ZeroAddress();
    /// @notice CREATE2 failed: address already used, or the token constructor reverted.
    error DeployFailed();

    /// @param factory_ The factory bound to this deployer. Reverts with `ZeroAddress` when zero.
    constructor(address factory_) {
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
    }

    /// @notice Deploys the token with CREATE2. Factory only; `launcher` must be the factory.
    /// @dev    Reverts with `NotFactory`, `LauncherMismatch` or `DeployFailed`.
    /// @param t           Token config.
    /// @param supply      Supply minted to `launcher`.
    /// @param restriction Restriction config (validated by the token constructor).
    /// @param pinned      Factory seeded allowlist entries the coin admin cannot remove.
    /// @param canon       Canonical hook, PoolManager, tickSpacing.
    /// @param launcher    The factory; the token's `launcher` and mint recipient.
    /// @param salt        `keccak256(abi.encode(sender, configHash))`, computed by the factory.
    /// @return token      Deployed token address.
    function deploy(
        IArtCoinsFactoryV2.TokenConfigV2 memory t,
        uint256 supply,
        IArtCoinsFactoryV2.RestrictionConfigV2 memory restriction,
        address[] memory pinned,
        ArtCoinsTokenV2.CanonicalPool memory canon,
        address launcher,
        bytes32 salt
    ) external returns (address token) {
        if (msg.sender != factory) revert NotFactory();
        if (launcher != factory) revert LauncherMismatch();
        bytes memory initCode = _initCode(t, supply, restriction, pinned, canon, launcher);
        assembly ("memory-safe") {
            token := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        if (token == address(0)) revert DeployFailed();
        emit TokenDeployed(token, salt);
    }

    /// @notice Address `deploy` yields for the same arguments.
    /// @param t           Token config.
    /// @param supply      Supply minted to `launcher`.
    /// @param restriction Restriction config.
    /// @param pinned      Factory seeded allowlist entries.
    /// @param canon       Canonical hook, PoolManager, tickSpacing.
    /// @param launcher    The token's `launcher` and mint recipient.
    /// @param salt        CREATE2 salt.
    /// @return The predicted token address.
    function predict(
        IArtCoinsFactoryV2.TokenConfigV2 memory t,
        uint256 supply,
        IArtCoinsFactoryV2.RestrictionConfigV2 memory restriction,
        address[] memory pinned,
        ArtCoinsTokenV2.CanonicalPool memory canon,
        address launcher,
        bytes32 salt
    ) external view returns (address) {
        bytes32 h = keccak256(_initCode(t, supply, restriction, pinned, canon, launcher));
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, h))))
        );
    }

    /// @inheritdoc IConstantsBound
    function constantsHash() external pure returns (bytes32) {
        return Constants.hash();
    }

    function _initCode(
        IArtCoinsFactoryV2.TokenConfigV2 memory t,
        uint256 supply,
        IArtCoinsFactoryV2.RestrictionConfigV2 memory restriction,
        address[] memory pinned,
        ArtCoinsTokenV2.CanonicalPool memory canon,
        address launcher
    ) private pure returns (bytes memory) {
        return abi.encodePacked(
            type(ArtCoinsTokenV2).creationCode,
            abi.encode(t, supply, restriction, pinned, canon, launcher)
        );
    }
}
