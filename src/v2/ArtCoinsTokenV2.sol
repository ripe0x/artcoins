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
/// @notice Art coin: Solady ERC20 with Permit and the infinite Permit2 allowance, a transfer
///         allowlist and a replaceable metadata renderer.
/// @dev    Deployed by `ArtCoinsDeployerV2` via CREATE2. The whole supply is minted to the
///         launcher. Name, symbol, initial supply, `launcher`, `canonicalHook`,
///         `canonicalPoolId` and `poolManager` are fixed at construction.
///
///         Transfer rule: `restricted` is set at construction and `unrestrict` clears it
///         permanently. While restricted, a transfer reverts unless `from` or `to` is on the
///         allowlist, or one side is the PoolManager and the amount fits the transient allowance
///         the canonical hook granted for a canonical swap in the same transaction. The transfer
///         consumes the allowance. Mint and burn bypass the rule. While not restricted, every
///         transfer passes.
///
///         Authority: the launcher (the factory) receives the initial supply and holds no
///         privilege afterwards. The canonical hook is the sole caller of
///         `increaseTransferAllowance`. The coin admin calls `setAllowed`, `unrestrict`,
///         `lock`, `updateAdmin`, `renounceAdmin` and the metadata setters (image,
///         description, renderer). `lock` freezes `setAllowed`, `unrestrict` and the hook's
///         coin admin setters. `renounceAdmin` freezes every admin function.
///
///         Metadata: `contractURI` and `tokenURI` return `IMetadataRenderer.contractURI(this)`
///         when a renderer is set, else a built in json over the stored fields.
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
    ///         setter. Values are defined in `Constants`.
    uint256 public constant MAX_NAME_BYTES = Constants.MAX_NAME_BYTES;
    uint256 public constant MAX_SYMBOL_BYTES = Constants.MAX_SYMBOL_BYTES;
    uint256 public constant MAX_IMAGE_BYTES = Constants.MAX_IMAGE_BYTES;
    uint256 public constant MAX_DESCRIPTION_BYTES = Constants.MAX_DESCRIPTION_BYTES;
    /// @notice `StringTooLong.field` codes, defined in `Constants`.
    uint8 public constant FIELD_NAME = Constants.FIELD_NAME;
    uint8 public constant FIELD_SYMBOL = Constants.FIELD_SYMBOL;
    uint8 public constant FIELD_IMAGE = Constants.FIELD_IMAGE;
    uint8 public constant FIELD_DESCRIPTION = Constants.FIELD_DESCRIPTION;

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
    bool public locked;

    mapping(address => bool) private _allowed;

    // ── construction ──────────────────────────────────────────────────────

    /// @param t        Token config. `totalSupply` is ignored; `supply` is what is minted.
    /// @param supply   Supply minted to `launcher_`.
    /// @param r        Restriction config. `restricted` and the full allowlist
    ///                 the factory assembled (empty when not restricted).
    /// @param canon    Canonical pool inputs from the factory.
    /// @param launcher_ The factory. Receives the supply and is the `launcher` tag.
    constructor(
        IArtCoinsFactoryV2.TokenConfigV2 memory t,
        uint256 supply,
        IArtCoinsFactoryV2.RestrictionConfigV2 memory r,
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
            for (uint256 i; i < n; ++i) {
                address a = r.allowed[i];
                if (a == address(0)) revert RestrictionConfigInvalid();
                // An entry for the PoolManager or the hook would move coin out of the pool
                // without consuming the per swap allowance.
                if (a == canon.poolManager || a == canon.hook) revert AllowedForbidden(a);
                _allowed[a] = true;
                emit AllowedSet(a, true);
            }
        } else if (r.allowed.length != 0) {
            // An unrestricted coin takes an empty allowlist.
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

    /// @dev Solady inlines the balance move in `transfer` and `transferFrom`. Both are
    ///      overridden to call `_route`. `_spendAllowance` applies the Permit2 allowance.
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

    /// @dev Every transfer and transferFrom passes through here. Mint and burn skip it. While
    ///      restricted, a move with no allowlisted side needs the PoolManager on one side and
    ///      a transient allowance of at least `amount`, which it consumes.
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
    /// @dev A zero amount or a different pool id returns without effect, so a misrouted hook
    ///      call cannot revert a swap.
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
        if (locked) revert CoinLocked();
        if (account == address(0)) revert ZeroAddress();
        if (account == poolManager || account == canonicalHook) revert AllowedForbidden(account);
        _allowed[account] = allowed;
        emit AllowedSet(account, allowed);
    }

    /// @inheritdoc IArtCoinsTokenV2
    function unrestrict() external {
        if (msg.sender != _admin) revert NotAdmin();
        if (locked) revert CoinLocked();
        if (!restricted) revert NotRestricted();
        restricted = false;
        emit Unrestricted();
    }

    /// @inheritdoc IArtCoinsTokenV2
    /// @dev The hook reads `locked` to freeze its coin admin setters.
    function lock() external {
        if (msg.sender != _admin) revert NotAdmin();
        if (locked) revert CoinLocked();
        locked = true;
        emit Locked();
    }

    /// @inheritdoc IArtCoinsTokenV2
    function isAllowed(address account) external view returns (bool) {
        return _allowed[account];
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
    /// @dev Sets the admin to the zero address, which freezes every admin function. The hook's
    ///      coin admin setters require `admin()` as caller and freeze too.
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
    /// @dev Zero selects the built in json. A nonzero renderer must have code. `contractURI` and
    ///      `tokenURI` call the renderer on every read, so the admin replaces a reverting renderer
    ///      with this function.
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

    /// @dev Each field is passed through `LibString.escapeJSON`, so any bytes give valid json.
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
