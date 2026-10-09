// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title  IArtCoinsTokenV2
/// @notice v2 coin surface beyond erc20. The canonical pool, hook and launcher
///         are immutable. `restricted` is set at launch. While restricted, a
///         transfer passes if it is a mint or burn, if either side is on the
///         allowlist, or if one side is the PoolManager and the amount fits the
///         transient allowance the canonical hook granted this transaction. The
///         coin admin manages the allowlist, may turn restriction off once, and
///         may lock the allowlist and the switch permanently.
interface IArtCoinsTokenV2 {
    // ── events ────────────────────────────────────────────────────────────

    /// @notice An allowlist entry changed. `pinned` marks a factory seeded entry
    ///         the coin admin cannot remove. Emitted once per seed at construction
    ///         and on every `setAllowed`.
    event AllowedSet(address indexed account, bool allowed, bool pinned);
    /// @notice Restriction turned off. Every transfer passes after this.
    event Unrestricted();
    /// @notice The allowlist and the restriction switch are frozen.
    event AllowlistLocked();
    /// @notice The bounty and reward recipient setters on the hook and locker are frozen.
    event RecipientsLocked();
    /// @notice The admin changed the description.
    event UpdateDescription(string description);
    /// @notice The admin changed the image url.
    event UpdateImage(string image);
    /// @notice The coin admin changed.
    event UpdateAdmin(address indexed oldAdmin, address indexed newAdmin);
    /// @notice The metadata renderer changed.
    event MetadataRendererUpdated(address indexed renderer);
    /// @notice The contract metadata changed (image, description or renderer).
    event ContractURIUpdated();
    /// @notice The coin admin was renounced; the admin is now the zero address.
    event AdminRenounced(address indexed admin);

    // ── errors ────────────────────────────────────────────────────────────

    /// @notice The caller is not the coin admin.
    error NotAdmin();
    /// @notice The caller is not the canonical hook.
    error NotCanonicalHook();
    /// @notice A required address argument is the zero address.
    error ZeroAddress();
    /// @notice The renderer has no code.
    error InvalidRenderer();
    /// @notice The restriction config is inconsistent: too many entries, a zero
    ///         entry, or a non empty allowlist on an unrestricted coin.
    error RestrictionConfigInvalid();
    /// @notice The canonical pool inputs are invalid (tickSpacing must be positive).
    error CanonicalPoolInvalid();
    /// @notice An allowlist entry names the PoolManager or the canonical hook.
    error AllowedForbidden(address account);
    /// @notice `setAllowed` tried to remove a factory seeded (pinned) entry.
    error AllowedPinned(address account);
    /// @notice The allowlist and the restriction switch are frozen.
    error AllowlistAlreadyLocked();
    /// @notice The bounty and reward recipient setters are frozen.
    error RecipientsAlreadyLocked();
    /// @notice Restriction is already off.
    error NotRestricted();
    /// @notice Restricted transfer with no allowlisted side and no sufficient
    ///         PoolManager allowance.
    error TransferRestricted(address from, address to, uint256 amount);
    /// @notice A string field exceeds its byte cap. `field`: 0 name, 1 symbol,
    ///         2 image, 3 description. Caps 64, 16, 2048, 4096 bytes.
    error StringTooLong(uint8 field, uint256 len);

    // ── restriction reads ─────────────────────────────────────────────────

    /// @notice True while holder to holder transfers need an allowlisted side.
    function restricted() external view returns (bool);
    /// @notice True once the allowlist and the restriction switch are frozen.
    function allowlistLocked() external view returns (bool);
    /// @notice True once the bounty and reward recipient setters on the hook and
    ///         locker are frozen.
    function recipientsLocked() external view returns (bool);
    /// @notice True if `account` is on the allowlist.
    function isAllowed(address account) external view returns (bool);
    /// @notice True if `account` is a factory seeded entry the coin admin cannot remove.
    function isPinned(address account) external view returns (bool);
    /// @notice True if a holder to holder transfer from `from` to `to` would be
    ///         rejected: restriction is on and neither side is allowlisted. This
    ///         ignores the per swap PoolManager transient allowance, so a transfer
    ///         with the PoolManager on one side may still pass within that
    ///         allowance even when this returns true.
    function isTransferRestricted(address from, address to) external view returns (bool);
    /// @notice Remaining PoolManager transfer allowance this transaction. Stored
    ///         in transient storage, so an `eth_call` outside a transaction reads 0.
    function transferAllowance() external view returns (uint256);
    /// @notice The canonical v4 hook.
    function canonicalHook() external view returns (address);
    /// @notice The canonical pool id.
    function canonicalPoolId() external view returns (bytes32);
    /// @notice The hook's PoolManager.
    function poolManager() external view returns (address);

    // ── version tag ───────────────────────────────────────────────────────

    /// @notice Factory that launched this coin.
    function launcher() external view returns (address);
    /// @notice Constants.STACK_VERSION.
    function launcherVersion() external pure returns (uint16);

    // ── restriction admin (coin admin only) ───────────────────────────────

    /// @notice Add or remove an allowlist entry. Reverts once the allowlist is
    ///         locked, if `account` is zero, the PoolManager or the hook, or if
    ///         it removes a pinned entry.
    function setAllowed(address account, bool allowed) external;
    /// @notice Turn restriction off permanently. Reverts once locked.
    function unrestrict() external;
    /// @notice Freeze the allowlist and the restriction switch permanently.
    function lockAllowlist() external;
    /// @notice Freeze the bounty and reward recipient setters on the hook and
    ///         locker permanently.
    function lockRecipients() external;

    // ── canonical hook only ───────────────────────────────────────────────

    /// @notice Increase the transient PoolManager transfer allowance for a
    ///         canonical swap this transaction. Canonical hook only. A zero
    ///         amount or a call for another pool is a no op and never reverts.
    function increaseTransferAllowance(bytes32 poolId, uint256 amount) external;

    // ── metadata (coin admin only for setters) ─────────────────────────────

    /// @notice The coin admin, or the zero address once renounced.
    function admin() external view returns (address);
    /// @notice The stored image url. A renderer may read or ignore it.
    function imageUrl() external view returns (string memory);
    /// @notice The stored description. A renderer may read or ignore it.
    function description() external view returns (string memory);
    /// @notice The metadata renderer, or the zero address for the built in json.
    function metadataRenderer() external view returns (address);
    /// @notice Canonical contract metadata to read. Returns the renderer output
    ///         when a renderer is set, else the built in json over the stored fields.
    function contractURI() external view returns (string memory);
    /// @notice Same output as `contractURI`.
    function tokenURI() external view returns (string memory);
    /// @notice Set the coin admin. Coin admin only; `admin_` must be nonzero.
    function updateAdmin(address admin_) external;
    /// @notice Renounce the coin admin. Freezes every admin only function.
    function renounceAdmin() external;
    /// @notice Set the image url. Coin admin only; bounded by MAX_IMAGE_BYTES.
    function updateImage(string calldata image_) external;
    /// @notice Set the description. Coin admin only; bounded by MAX_DESCRIPTION_BYTES.
    function updateDescription(string calldata description_) external;
    /// @notice Set the metadata renderer. Coin admin only; zero selects the
    ///         built in json, a nonzero renderer must have code.
    function setMetadataRenderer(address renderer_) external;
    /// @notice Burn `amount` from the caller.
    function burn(uint256 amount) external;
    /// @notice Burn `amount` from `account` using the caller's allowance.
    function burnFrom(address account, uint256 amount) external;
}
