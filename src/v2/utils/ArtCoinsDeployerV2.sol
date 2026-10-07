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
///         this first. There is no setter and no owner.
///
///         Address binding (b4): the factory passes
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

    event TokenDeployed(address indexed token, bytes32 indexed salt);

    error NotFactory();
    error LauncherMismatch();
    error ZeroAddress();
    /// @notice CREATE2 failed: address already used, or the token constructor reverted.
    error DeployFailed();

    constructor(address factory_) {
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
    }

    /// @notice Deploys the token. Factory only; `launcher` must be the factory.
    /// @param t           Token config.
    /// @param supply      Supply minted to `launcher`.
    /// @param restriction Restriction config (validated by the token constructor).
    /// @param canon       Canonical hook, PoolManager, tickSpacing.
    /// @param launcher    The factory; the token's `launcher` and mint recipient.
    /// @param salt        `keccak256(abi.encode(sender, configHash))`, computed by the factory.
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
