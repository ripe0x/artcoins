// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev Getters of the v2 factory read by `ExtensionRecipient`.
interface IFactoryRecipientProbe {
    function poolManager() external view returns (address);
    function enabledExtensions(address extension) external view returns (bool);
    function everEnabledExtensions(address extension) external view returns (bool);
}

/// @title  ExtensionRecipient
/// @notice Reject set for addresses that a launch extension pays out to.
/// @dev    A contract in the stack cannot release coins or accept eth it did not
///         expect, so it is rejected as a recipient: the calling extension, the
///         factory, the coin, the launch hook, the PoolManager and every extension
///         the factory has enabled or ever enabled.
library ExtensionRecipient {
    /// @param factory The v2 factory.
    /// @param poolManager The PoolManager of the factory.
    /// @param account Candidate recipient.
    /// @param token The launched coin.
    /// @param hook The launch hook.
    /// @return True if `account` cannot be a recipient.
    function isReserved(
        address factory,
        address poolManager,
        address account,
        address token,
        address hook
    ) internal view returns (bool) {
        if (
            account == address(this) || account == factory || account == token || account == hook
                || account == poolManager
        ) return true;
        IFactoryRecipientProbe f = IFactoryRecipientProbe(factory);
        return f.enabledExtensions(account) || f.everEnabledExtensions(account);
    }

    /// @dev Same as `isReserved` with the PoolManager read from the factory.
    function isReservedByFactory(address factory, address account, address token, address hook)
        internal
        view
        returns (bool)
    {
        return
            isReserved(factory, IFactoryRecipientProbe(factory).poolManager(), account, token, hook);
    }
}
