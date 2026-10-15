// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Constants} from "../../Constants.sol";
import {ArtCoinsTokenV2} from "../ArtCoinsTokenV2.sol";
import {IArtCoinsFactoryV2} from "../interfaces/IArtCoinsFactoryV2.sol";
import {IConstantsBound} from "../interfaces/IConstantsBound.sol";

/// @title  ArtCoinsDeployerV2
/// @notice CREATE2 deployer for `ArtCoinsTokenV2`, bound to one factory.
/// @dev    The factory runtime plus the token initcode exceeds the EIP-170 code size limit, so
///         the token initcode is held here. `factory` is an immutable set at construction and
///         is the only caller of `deploy`. The factory is deployed first, then
///         `new ArtCoinsDeployerV2(factory)`, then `factory.setTokenDeployer`.
///
///         The factory passes `salt = keccak256(abi.encode(sender, configHash))`. The initcode
///         carries every constructor argument, so the token address is a function of
///         (this deployer, sender, full config). The same config from a different sender
///         yields a different address.
///
///         `deploy` and `predict` build the same initcode, so a prediction equals the deploy.
contract ArtCoinsDeployerV2 is IConstantsBound {
    /// @notice The only caller of `deploy`, and the token's `launcher`.
    address public immutable factory;

    /// @notice A token was deployed.
    /// @param token Deployed token address.
    /// @param salt CREATE2 salt used.
    event TokenDeployed(address indexed token, bytes32 indexed salt);

    /// @notice The caller of `deploy` is not the factory.
    error NotFactory();
    /// @notice The `launcher` argument of `deploy` differs from `factory`.
    error LauncherMismatch();
    /// @notice The factory address given at construction is zero.
    error ZeroAddress();
    /// @notice CREATE2 returned zero: the address is occupied or the token constructor reverted.
    error DeployFailed();

    /// @param factory_ The bound factory. Zero reverts `ZeroAddress`.
    constructor(address factory_) {
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
    }

    /// @notice Deploys the token with CREATE2. Factory only.
    /// @dev    Reverts `NotFactory`, `LauncherMismatch` or `DeployFailed`.
    /// @param t           Token config.
    /// @param supply      Supply minted to `launcher`.
    /// @param restriction Restriction config, validated by the token constructor.
    /// @param canon       Canonical hook, PoolManager, tickSpacing.
    /// @param launcher    The factory. Becomes the token's `launcher` and mint recipient.
    /// @param salt        `keccak256(abi.encode(sender, configHash))`, computed by the factory.
    /// @return token      Deployed token address.
    function deploy(
        IArtCoinsFactoryV2.TokenConfigV2 memory t,
        uint256 supply,
        IArtCoinsFactoryV2.RestrictionConfigV2 memory restriction,
        ArtCoinsTokenV2.CanonicalPool memory canon,
        address launcher,
        bytes32 salt
    ) external returns (address token) {
        if (msg.sender != factory) revert NotFactory();
        if (launcher != factory) revert LauncherMismatch();
        bytes memory initCode = _initCode(t, supply, restriction, canon, launcher);
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
    /// @param canon       Canonical hook, PoolManager, tickSpacing.
    /// @param launcher    The token's `launcher` and mint recipient.
    /// @param salt        CREATE2 salt.
    /// @return The predicted token address.
    function predict(
        IArtCoinsFactoryV2.TokenConfigV2 memory t,
        uint256 supply,
        IArtCoinsFactoryV2.RestrictionConfigV2 memory restriction,
        ArtCoinsTokenV2.CanonicalPool memory canon,
        address launcher,
        bytes32 salt
    ) external view returns (address) {
        bytes32 h = keccak256(_initCode(t, supply, restriction, canon, launcher));
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
        ArtCoinsTokenV2.CanonicalPool memory canon,
        address launcher
    ) private pure returns (bytes memory) {
        return abi.encodePacked(
            type(ArtCoinsTokenV2).creationCode, abi.encode(t, supply, restriction, canon, launcher)
        );
    }
}
