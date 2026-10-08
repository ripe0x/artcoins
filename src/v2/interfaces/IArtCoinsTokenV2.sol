// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title  IArtCoinsTokenV2
/// @notice v2 art coin surface beyond erc20. The canonical pool, hook and
///         launcher are immutable. `restricted` is set at launch. While
///         restricted, a transfer passes if it is a mint or burn, if either
///         side is on the allowlist, or if one side is the PoolManager and the
///         amount fits the transient allowance the canonical hook granted this
///         transaction. The coin admin manages the allowlist, may turn
///         restriction off once, and may lock both permanently.
interface IArtCoinsTokenV2 {
    // ── events ────────────────────────────────────────────────────────────

    /// @notice An allowlist entry changed. Emitted once per seed at construction.
    event AllowedSet(address indexed account, bool allowed);
    /// @notice Restriction turned off. Transfers pass without the allowlist after this.
    event Unrestricted();
    /// @notice Allowlist and the restriction switch frozen.
    event Locked();
    /// @notice Bounty and reward recipient changes frozen.
    event RecipientsLocked();

    event Verified(address indexed admin, address indexed token);
    event UpdateImage(string image);
    event UpdateMetadata(string metadata);
    event UpdateAdmin(address indexed oldAdmin, address indexed newAdmin);
    event MetadataRendererUpdated(address indexed renderer);
    event ContractURIUpdated();
    event AdminRenounced(address indexed admin);

    // ── errors ────────────────────────────────────────────────────────────

    error NotAdmin();
    error NotOriginalAdmin();
    error NotCanonicalHook();
    error AlreadyVerified();
    error ZeroAddress();
    error InvalidRenderer();
    error RestrictionConfigInvalid();
    /// @notice The canonical pool inputs are invalid (tickSpacing must be positive).
    error CanonicalPoolInvalid();
    /// @notice An allowlist entry names the PoolManager or the canonical hook.
    error AllowedForbidden(address account);
    /// @notice `setAllowed` tried to remove a factory seeded (pinned) entry.
    error AllowedPinned(address account);
    /// @notice The allowlist and the restriction switch are frozen.
    error AlreadyLocked();
    /// @notice Restriction is already off.
    error NotRestricted();
    /// @notice Restricted transfer with no allowlisted side and no sufficient
    ///         PoolManager allowance.
    error TransferRestricted(address from, address to, uint256 amount);
    /// @notice A string field exceeds its byte cap. `field`: 0 name, 1 symbol,
    ///         2 image, 3 metadata, 4 context. Caps 64, 16, 2048, 4096, 4096 bytes.
    error StringTooLong(uint8 field, uint256 len);

    // ── restriction reads ─────────────────────────────────────────────────

    function restricted() external view returns (bool);
    function locked() external view returns (bool);
    /// @notice The bounty and reward recipient setters on the hook and locker
    ///         are frozen once this is set.
    function recipientsLocked() external view returns (bool);
    function isAllowed(address account) external view returns (bool);
    /// @notice A factory seeded entry the coin admin cannot remove.
    function isPinned(address account) external view returns (bool);
    /// @notice Remaining PoolManager transfer allowance this transaction.
    function transferAllowance() external view returns (uint256);
    function canonicalHook() external view returns (address);
    function canonicalPoolId() external view returns (bytes32);
    function poolManager() external view returns (address);

    // ── version tag ───────────────────────────────────────────────────────

    /// @notice Factory that launched this token.
    function launcher() external view returns (address);
    /// @notice Constants.STACK_VERSION.
    function launcherVersion() external pure returns (uint16);

    // ── restriction admin (coin admin only) ───────────────────────────────

    /// @notice Add or remove an allowlist entry. Reverts once locked.
    function setAllowed(address account, bool allowed) external;
    /// @notice Turn restriction off permanently. Reverts once locked.
    function unrestrict() external;
    /// @notice Freeze the allowlist and the restriction switch permanently.
    function lock() external;
    /// @notice Freeze the bounty and reward recipient setters on the hook and
    ///         locker permanently. One way.
    function lockRecipients() external;

    // ── canonical hook only ───────────────────────────────────────────────

    /// @notice Increase the transient PoolManager transfer allowance for a
    ///         canonical swap this transaction. No op for another pool.
    function increaseTransferAllowance(bytes32 poolId, uint256 amount) external;

    // ── metadata (as v1) ──────────────────────────────────────────────────

    function admin() external view returns (address);
    function originalAdmin() external view returns (address);
    function imageUrl() external view returns (string memory);
    function metadata() external view returns (string memory);
    function context() external view returns (string memory);
    function metadataRenderer() external view returns (address);
    function isVerified() external view returns (bool);
    function contractURI() external view returns (string memory);
    function tokenURI() external view returns (string memory);
    function updateAdmin(address admin_) external;
    function renounceAdmin() external;
    function updateImage(string calldata image_) external;
    function updateMetadata(string calldata metadata_) external;
    function setMetadataRenderer(address renderer_) external;
    function verify() external;
    function burn(uint256 amount) external;
    function burnFrom(address account, uint256 amount) external;
}
