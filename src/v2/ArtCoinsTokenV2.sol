// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "solady/tokens/ERC20.sol";
import {LibString} from "solady/utils/LibString.sol";

import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {Constants} from "../Constants.sol";
import {IMetadataRenderer} from "../interfaces/IMetadataRenderer.sol";

import {IArtCoinsFactoryV2} from "./interfaces/IArtCoinsFactoryV2.sol";
import {IArtCoinsTokenV2} from "./interfaces/IArtCoinsTokenV2.sol";
import {IConstantsBound} from "./interfaces/IConstantsBound.sol";

/// @title  ArtCoinsTokenV2
/// @notice v2 art coin. Solady ERC20 with Permit and the fixed infinite
///         Permit2 allowance.
///
///         `restricted` is set at construction; `unrestrict` is its only writer
///         and clears it permanently. While restricted, a holder to holder
///         transfer reverts unless either side is on the allowlist. A transfer
///         with the PoolManager on one side passes up to the transient allowance
///         the canonical hook grants for a canonical swap this transaction,
///         which the transfer consumes. Mint and burn bypass this rule. While
///         not restricted, every transfer passes.
///
///         Frozen at construction: name, symbol, supply, launcher, canonical
///         hook, pool id, PoolManager. The coin admin manages the allowlist,
///         may call `unrestrict` once, may `lockAllowlist` the allowlist and the
///         switch, and may change the cosmetic fields (image, description, renderer).
/// @dev    Deployed by `ArtCoinsDeployerV2` via CREATE2. The whole supply is
///         minted to the launcher (the factory).
contract ArtCoinsTokenV2 is ERC20, IArtCoinsTokenV2, IConstantsBound {
    using PoolIdLibrary for PoolKey;

    /// @notice Launch inputs the token cannot derive from its own config.
    struct CanonicalPool {
        address hook; // canonical v4 hook (PoolConfigV2.hook)
        address poolManager; // the hook's PoolManager
        int24 tickSpacing; // PoolConfigV2.tickSpacing
    }

    // ── constants ─────────────────────────────────────────────────────────

    /// @dev Transient PoolManager transfer allowance granted this transaction.
    bytes32 private constant _ALLOWANCE_SLOT = keccak256("artcoins.tokenV2.transferAllowance");

    /// @notice String caps in bytes, enforced at construction and in every
    ///         setter. The factory checks the same caps before deploying.
    uint256 public constant MAX_NAME_BYTES = 64;
    uint256 public constant MAX_SYMBOL_BYTES = 16;
    uint256 public constant MAX_IMAGE_BYTES = 2048;
    uint256 public constant MAX_DESCRIPTION_BYTES = 4096;
    /// @notice `StringTooLong.field` codes.
    uint8 public constant FIELD_NAME = 0;
    uint8 public constant FIELD_SYMBOL = 1;
    uint8 public constant FIELD_IMAGE = 2;
    uint8 public constant FIELD_DESCRIPTION = 3;

    // ── immutables ────────────────────────────────────────────────────────

    /// @inheritdoc IArtCoinsTokenV2
    address public immutable canonicalHook;
    /// @inheritdoc IArtCoinsTokenV2
    bytes32 public immutable canonicalPoolId;
    /// @inheritdoc IArtCoinsTokenV2
    address public immutable poolManager;
    /// @inheritdoc IArtCoinsTokenV2
    address public immutable launcher;

    // ── storage ───────────────────────────────────────────────────────────

    string private _name;
    string private _symbol;
    string private _description;
    string private _image;
    address private _admin;
    address private _metadataRenderer;

    /// @inheritdoc IArtCoinsTokenV2
    bool public restricted;
    /// @inheritdoc IArtCoinsTokenV2
    bool public allowlistLocked;
    /// @inheritdoc IArtCoinsTokenV2
    bool public recipientsLocked;

    mapping(address => bool) private _allowed;
    /// @dev Allowlist entries the factory seeded (the stack escrow, this launch's
    ///      locker and the launch extensions). `setAllowed` keeps a pinned entry
    ///      on the list; the coin admin can add and remove its own entries only.
    mapping(address => bool) private _pinned;

    // ── construction ──────────────────────────────────────────────────────

    /// @param t        Token config. `totalSupply` is ignored; `supply` is what is minted.
    /// @param supply   Supply minted to `launcher_`.
    /// @param r        Restriction config. `restricted` and the full allowlist
    ///                 the factory assembled (empty when not restricted).
    /// @param pinned   The subset of `r.allowed` the coin admin cannot remove.
    /// @param canon    Canonical pool inputs from the factory.
    /// @param launcher_ The factory. Receives the supply and is the `launcher` tag.
    constructor(
        IArtCoinsFactoryV2.TokenConfigV2 memory t,
        uint256 supply,
        IArtCoinsFactoryV2.RestrictionConfigV2 memory r,
        address[] memory pinned,
        CanonicalPool memory canon,
        address launcher_
    ) {
        if (t.tokenAdmin == address(0) || launcher_ == address(0)) {
            revert ZeroAddress();
        }
        if (t.renderer != address(0) && t.renderer.code.length == 0) revert InvalidRenderer();
        if (canon.hook == address(0) || canon.poolManager == address(0)) revert ZeroAddress();
        if (canon.tickSpacing <= 0) revert CanonicalPoolInvalid();

        _cap(t.name, MAX_NAME_BYTES, FIELD_NAME);
        _cap(t.symbol, MAX_SYMBOL_BYTES, FIELD_SYMBOL);
        _cap(t.image, MAX_IMAGE_BYTES, FIELD_IMAGE);
        _cap(t.description, MAX_DESCRIPTION_BYTES, FIELD_DESCRIPTION);

        _name = t.name;
        _symbol = t.symbol;
        _admin = t.tokenAdmin;
        _image = t.image;
        _description = t.description;
        _metadataRenderer = t.renderer;
        launcher = launcher_;

        canonicalHook = canon.hook;
        poolManager = canon.poolManager;
        // Native eth (address 0) always sorts first; the hook creates dynamic fee pools.
        canonicalPoolId = PoolId.unwrap(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(address(this)),
                fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
                tickSpacing: canon.tickSpacing,
                hooks: IHooks(canon.hook)
            }).toId()
        );

        restricted = r.restricted;
        if (r.restricted) {
            uint256 n = r.allowed.length;
            if (n > Constants.MAX_ALLOWED) revert RestrictionConfigInvalid();
            for (uint256 i; i < pinned.length; ++i) {
                _pinned[pinned[i]] = true;
            }
            for (uint256 i; i < n; ++i) {
                address a = r.allowed[i];
                if (a == address(0)) revert RestrictionConfigInvalid();
                // the PoolManager and the canonical hook gate the swap path; an
                // allowlist entry for either would let coin leave the pool
                // without consuming the per swap allowance.
                if (a == canon.poolManager || a == canon.hook) revert AllowedForbidden(a);
                _allowed[a] = true;
                emit AllowedSet(a, true, _pinned[a]);
            }
        } else if (r.allowed.length != 0 || pinned.length != 0) {
            // an unrestricted coin carries no allowlist.
            revert RestrictionConfigInvalid();
        }

        _mint(launcher_, supply);
    }

    function _cap(string memory v, uint256 max, uint8 field) private pure {
        uint256 len = bytes(v).length;
        if (len > max) revert StringTooLong(field, len);
    }

    // ── erc20 ─────────────────────────────────────────────────────────────

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    /// @dev Solady inlines balance moves in `transfer`/`transferFrom`, so both
    ///      are overridden and routed through `_route`. `transferFrom` debits
    ///      the full `amount` once (Permit2 short circuit preserved).
    function transfer(address to, uint256 amount) public override returns (bool) {
        _route(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _route(from, to, amount);
        return true;
    }

    /// @inheritdoc IArtCoinsTokenV2
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /// @inheritdoc IArtCoinsTokenV2
    function burnFrom(address account, uint256 amount) external {
        _spendAllowance(account, msg.sender, amount);
        _burn(account, amount);
    }

    // ── transfer rule ──────────────────────────────────────────────────────

    /// @dev Single chokepoint for every holder to holder move. Mint and burn
    ///      skip it. While restricted, a move with no allowlisted side passes
    ///      only when one side is the PoolManager and the transient allowance
    ///      covers it; the allowance is consumed.
    function _route(address from, address to, uint256 amount) private {
        if (restricted && !_allowed[from] && !_allowed[to]) {
            address pm = poolManager;
            if (from != pm && to != pm) revert TransferRestricted(from, to, amount);
            uint256 a = _tload(_ALLOWANCE_SLOT);
            if (amount > a) revert TransferRestricted(from, to, amount);
            unchecked {
                _tstore(_ALLOWANCE_SLOT, a - amount);
            }
        }
        _transfer(from, to, amount);
    }

    /// @inheritdoc IArtCoinsTokenV2
    /// @dev A zero amount or a call for another pool is a no op, never reverts,
    ///      so a hook misroute cannot brick a swap.
    function increaseTransferAllowance(bytes32 poolId, uint256 amount) external {
        if (msg.sender != canonicalHook) revert NotCanonicalHook();
        if (poolId != canonicalPoolId || amount == 0) return;
        _tstore(_ALLOWANCE_SLOT, _tload(_ALLOWANCE_SLOT) + amount);
    }

    /// @inheritdoc IArtCoinsTokenV2
    function transferAllowance() external view returns (uint256) {
        return _tload(_ALLOWANCE_SLOT);
    }

    function _tload(bytes32 slot) private view returns (uint256 v) {
        assembly ("memory-safe") {
            v := tload(slot)
        }
    }

    function _tstore(bytes32 slot, uint256 v) private {
        assembly ("memory-safe") {
            tstore(slot, v)
        }
    }

    // ── restriction admin ──────────────────────────────────────────────────

    /// @inheritdoc IArtCoinsTokenV2
    function setAllowed(address account, bool allowed) external {
        if (msg.sender != _admin) revert NotAdmin();
        if (allowlistLocked) revert AllowlistAlreadyLocked();
        if (account == address(0)) revert ZeroAddress();
        if (account == poolManager || account == canonicalHook) revert AllowedForbidden(account);
        if (_pinned[account] && !allowed) revert AllowedPinned(account);
        _allowed[account] = allowed;
        emit AllowedSet(account, allowed, _pinned[account]);
    }

    /// @inheritdoc IArtCoinsTokenV2
    function unrestrict() external {
        if (msg.sender != _admin) revert NotAdmin();
        if (allowlistLocked) revert AllowlistAlreadyLocked();
        if (!restricted) revert NotRestricted();
        restricted = false;
        emit Unrestricted();
    }

    /// @inheritdoc IArtCoinsTokenV2
    function lockAllowlist() external {
        if (msg.sender != _admin) revert NotAdmin();
        if (allowlistLocked) revert AllowlistAlreadyLocked();
        allowlistLocked = true;
        emit AllowlistLocked();
    }

    /// @inheritdoc IArtCoinsTokenV2
    /// @dev The hook and locker read `recipientsLocked` to freeze the bounty and
    ///      reward recipient setters.
    function lockRecipients() external {
        if (msg.sender != _admin) revert NotAdmin();
        if (recipientsLocked) revert RecipientsAlreadyLocked();
        recipientsLocked = true;
        emit RecipientsLocked();
    }

    /// @inheritdoc IArtCoinsTokenV2
    function isAllowed(address account) external view returns (bool) {
        return _allowed[account];
    }

    /// @inheritdoc IArtCoinsTokenV2
    function isPinned(address account) external view returns (bool) {
        return _pinned[account];
    }

    /// @inheritdoc IArtCoinsTokenV2
    function isTransferRestricted(address from, address to) external view returns (bool) {
        return restricted && !_allowed[from] && !_allowed[to];
    }

    /// @inheritdoc IArtCoinsTokenV2
    function launcherVersion() external pure returns (uint16) {
        return Constants.STACK_VERSION;
    }

    /// @inheritdoc IConstantsBound
    function constantsHash() external pure returns (bytes32) {
        return Constants.hash();
    }

    // ── admin and metadata ──────────────────────────────────────────────────

    /// @inheritdoc IArtCoinsTokenV2
    function updateAdmin(address admin_) external {
        if (msg.sender != _admin) revert NotAdmin();
        if (admin_ == address(0)) revert ZeroAddress();
        address oldAdmin = _admin;
        _admin = admin_;
        emit UpdateAdmin(oldAdmin, admin_);
    }

    /// @inheritdoc IArtCoinsTokenV2
    /// @dev Freezes every admin only function (`setAllowed`, `unrestrict`,
    ///      `lockAllowlist`, `lockRecipients`, the metadata setters): each
    ///      requires the admin, which becomes the zero address. The hook and
    ///      locker recipient setters key on `admin()`, so they freeze too.
    function renounceAdmin() external {
        if (msg.sender != _admin) revert NotAdmin();
        address oldAdmin = _admin;
        _admin = address(0);
        emit UpdateAdmin(oldAdmin, address(0));
        emit AdminRenounced(oldAdmin);
    }

    /// @inheritdoc IArtCoinsTokenV2
    function updateImage(string calldata image_) external {
        if (msg.sender != _admin) revert NotAdmin();
        _cap(image_, MAX_IMAGE_BYTES, FIELD_IMAGE);
        _image = image_;
        emit UpdateImage(image_);
        emit ContractURIUpdated();
    }

    /// @inheritdoc IArtCoinsTokenV2
    function updateDescription(string calldata description_) external {
        if (msg.sender != _admin) revert NotAdmin();
        _cap(description_, MAX_DESCRIPTION_BYTES, FIELD_DESCRIPTION);
        _description = description_;
        emit UpdateDescription(description_);
        emit ContractURIUpdated();
    }

    /// @inheritdoc IArtCoinsTokenV2
    /// @dev Zero falls back to the built in json. A non zero renderer must have code.
    function setMetadataRenderer(address renderer_) external {
        if (msg.sender != _admin) revert NotAdmin();
        if (renderer_ != address(0) && renderer_.code.length == 0) revert InvalidRenderer();
        _metadataRenderer = renderer_;
        emit MetadataRendererUpdated(renderer_);
        emit ContractURIUpdated();
    }

    /// @inheritdoc IArtCoinsTokenV2
    function contractURI() external view returns (string memory) {
        return _resolveURI();
    }

    /// @inheritdoc IArtCoinsTokenV2
    function tokenURI() external view returns (string memory) {
        return _resolveURI();
    }

    function _resolveURI() private view returns (string memory) {
        address r = _metadataRenderer;
        if (r != address(0)) return IMetadataRenderer(r).contractURI(address(this));
        return _defaultContractURI();
    }

    /// @dev Every interpolated field goes through `LibString.escapeJSON`
    ///      (quotes, backslash, control chars), so any name bytes give valid json.
    function _defaultContractURI() private view returns (string memory) {
        string memory json = string.concat(
            '{"name":"',
            LibString.escapeJSON(_name),
            '","symbol":"',
            LibString.escapeJSON(_symbol),
            '","description":"',
            LibString.escapeJSON(_description),
            '","image":"',
            LibString.escapeJSON(_image),
            '"}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    /// @inheritdoc IArtCoinsTokenV2
    function admin() external view returns (address) {
        return _admin;
    }

    /// @inheritdoc IArtCoinsTokenV2
    function imageUrl() external view returns (string memory) {
        return _image;
    }

    /// @inheritdoc IArtCoinsTokenV2
    function description() external view returns (string memory) {
        return _description;
    }

    /// @inheritdoc IArtCoinsTokenV2
    function metadataRenderer() external view returns (address) {
        return _metadataRenderer;
    }

    /// @notice ERC-165: erc20, erc165, IArtCoinsTokenV2.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC20).interfaceId || interfaceId == type(IERC165).interfaceId
            || interfaceId == type(IArtCoinsTokenV2).interfaceId;
    }
}
