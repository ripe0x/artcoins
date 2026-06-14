// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "solady/tokens/ERC20.sol";
import {LibString} from "solady/utils/LibString.sol";

import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

import {IArtCoinsTaxable, TaxConfig, TaxVenue} from "./interfaces/IArtCoinsTaxable.sol";
import {IMetadataRenderer} from "./interfaces/IMetadataRenderer.sol";

/// @title ArtCoinsToken
/// @notice ArtCoins ERC20 token. Inherits Solady's `ERC20`, which gives every
///         token holder an infinite Permit2 allowance by default — Permit2 can
///         pull tokens via `transferFrom` without the holder ever calling
///         `approve`. `approve(PERMIT2, x)` reverts for any `x != type(uint256).max`.
///         This is what enables the 1-tx + 1-sig EOA sell flow against artcoins V4
///         (UR `PERMIT2_PERMIT` + `V4_SWAP` + `UNWRAP_WETH`).
/// @dev Deployed directly via CREATE2 by `ArtCoinsDeployer` (no proxy).
///
///      **Venue-scoped buy-side transfer tax (default-off).** Every art coin
///      carries a dormant transfer-tax feature; only a deploy that passes
///      `TaxConfig.enabled = true` switches it on (currently only PC's
///      111PUNKS). When dormant, `taxEnabled` is an immutable `false` and the
///      transfer path pays a single bytecode-resident short-circuit — no
///      storage read, no behavioral change. When enabled, the tax fires ONLY on
///      PCT leaving a known trading venue (a DEX buy / pool outflow) to a
///      non-allowlisted recipient; the canonical pool is exempted via an
///      amount-pinned transient budget the canonical hook attests per swap. See
///      `IArtCoinsTaxable`.
contract ArtCoinsToken is ERC20, IArtCoinsTaxable {
    /// @notice Reverts when a non-admin calls an admin-only function.
    error NotAdmin();
    /// @notice Reverts when a non-original-admin calls a function reserved for the original admin.
    error NotOriginalAdmin();
    /// @notice Reverts when `verify()` is called and the token has already been verified.
    error AlreadyVerified();
    /// @notice Reverts when the zero address is supplied where a real account is required.
    /// @dev Without this guard a typo could permanently brick admin-only paths via
    ///      `updateAdmin(address(0))`. Renouncing admin must be explicit
    ///      (use `renounceAdmin()`).
    error ZeroAddress();
    /// @notice Reverts when a candidate metadata renderer has no contract code.
    error InvalidRenderer();
    /// @notice Reverts when `setTaxBps` is called on a token whose tax feature
    ///         is not enabled (dormant deploy).
    error TaxNotEnabled();
    /// @notice Reverts when a requested tax rate exceeds the immutable parity cap.
    error TaxBpsTooHigh();
    /// @notice Reverts when an `enabled` `TaxConfig` is internally inconsistent
    ///         (e.g. zero burn sink / hook / pool manager, rate above the cap,
    ///         or a cap above the contract's hard ceiling).
    error TaxConfigInvalid();
    /// @notice Reverts when `attestCanonicalBudget` is called by anyone other
    ///         than the immutable canonical hook.
    error NotCanonicalHook();

    string private _name;
    string private _symbol;
    address private _originalAdmin;
    address private _admin;
    string private _metadata;
    string private _context;
    string private _image;
    bool private _verified;
    address private _metadataRenderer;

    // ─── Venue-scoped buy-side transfer tax (default-off) ──────────────────

    /// @notice bps denominator for the tax (10_000 = 100%).
    uint256 private constant TAX_DENOMINATOR = 10_000;
    /// @notice Compile-time hard ceiling for `taxBpsMax`. 2000 = 20%. The
    ///         side-pool sell-leak defense needs ~12.5–15% to stay at parity
    ///         against a 0.3%-LP side pool; PC launches the rate at 15% with
    ///         headroom to 20% so it can be tuned up via `setTaxBps` /
    ///         `TokenAdminPoker.setTokenTaxBps` if live side-pool behavior is
    ///         worse than expected. The configured `taxBpsMax` can never exceed
    ///         this ceiling, so "never predatory" holds structurally even
    ///         against a misconfigured deploy.
    uint16 private constant TAX_BPS_ABSOLUTE_MAX = 2000;
    /// @dev Transient-storage slot (EIP-1153) holding the canonical-exemption
    ///      budget the hook attests this tx. Accumulates within a tx, consumed
    ///      by venue→trader transfers, auto-clears at tx end. Per-contract slot;
    ///      no collision with regular storage (separate address space).
    bytes32 private constant _CANONICAL_BUDGET_SLOT =
        keccak256("artcoins.token.canonicalExemptionBudget.v1");

    /// @inheritdoc IArtCoinsTaxable
    bool public immutable taxEnabled;
    /// @inheritdoc IArtCoinsTaxable
    uint16 public immutable taxBpsMax;
    /// @inheritdoc IArtCoinsTaxable
    address public immutable taxBurnAddress;
    /// @inheritdoc IArtCoinsTaxable
    address public immutable canonicalHook;
    /// @inheritdoc IArtCoinsTaxable
    bytes32 public immutable canonicalPoolId;
    /// @notice V4 PoolManager singleton — the dominant venue (covers ALL V4
    ///         pools with one immutable compare on the transfer hot path).
    address public immutable taxPoolManager;

    /// @inheritdoc IArtCoinsTaxable
    /// @dev Mutable within `[0, taxBpsMax]` via the admin-gated `setTaxBps`.
    uint16 public taxBps;

    /// @dev V2/V3-style venues (derived from `address(this)` at construction).
    mapping(address => bool) private _taxVenue;
    /// @dev Allowlisted recipients exempt from the tax (matched on the `to` side).
    mapping(address => bool) private _taxExempt;

    /// @notice Emitted on every taxed transfer so frontends can render the
    ///         net/skim split cleanly (the ERC20 `Transfer` log shows two
    ///         events — net to recipient + skim to burn).
    event TaxApplied(
        address indexed from, address indexed to, uint256 gross, uint256 tax, uint256 net
    );
    /// @notice Emitted when the admin updates the buy-tax rate.
    event TaxBpsUpdated(uint16 oldBps, uint16 newBps);
    /// @notice Emitted once at construction when the tax feature is enabled,
    ///         pinning the canonical pool id + hook + launch parameters.
    event TaxEnabled(
        bytes32 indexed canonicalPoolId,
        address indexed canonicalHook,
        uint16 taxBps,
        uint16 taxBpsMax,
        address burnAddress
    );

    /// @notice Emitted when the original admin calls `verify()` for the first time.
    event Verified(address indexed admin, address indexed token);
    /// @notice Emitted when the token's image URL is updated.
    event UpdateImage(string image);
    /// @notice Emitted when the token's metadata string is updated.
    event UpdateMetadata(string metadata);
    /// @notice Emitted when the token admin role is transferred.
    event UpdateAdmin(address indexed oldAdmin, address indexed newAdmin);
    /// @notice Emitted when the metadata renderer contract is changed.
    event MetadataRendererUpdated(address indexed renderer);
    /// @notice Emitted on any metadata change to signal indexers (per ERC-7572).
    event ContractURIUpdated();
    /// @notice Emitted when the admin role is permanently renounced.
    event AdminRenounced(address indexed admin);

    /// @notice Deploys the token. Mints `maxSupply_` to `msg.sender` (the factory).
    /// @param name_ ERC20 name for the token.
    /// @param symbol_ ERC20 symbol for the token.
    /// @param maxSupply_ Total supply to mint to `msg.sender`.
    /// @param admin_ Initial admin address (also stored as the original admin).
    /// @param image_ Image URL used in the default contract URI.
    /// @param metadata_ Metadata/description string.
    /// @param context_ Freeform context string (for UIs or additional data).
    /// @param renderer_ Optional metadata renderer contract (zero = built-in default).
    /// @param tax_ Venue-scoped buy-tax config. Pass an `enabled = false` value
    ///        (the standard deploy path's `_emptyTaxConfig()`) for the dormant
    ///        default; only PC's launch passes `enabled = true`.
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 maxSupply_,
        address admin_,
        string memory image_,
        string memory metadata_,
        string memory context_,
        address renderer_,
        TaxConfig memory tax_
    ) {
        if (admin_ == address(0)) revert ZeroAddress();
        if (renderer_ != address(0) && renderer_.code.length == 0) revert InvalidRenderer();

        _name = name_;
        _symbol = symbol_;
        _originalAdmin = admin_;
        _admin = admin_;
        _image = image_;
        _metadata = metadata_;
        _context = context_;
        _metadataRenderer = renderer_;

        // ── Venue-scoped buy-side transfer tax (default-off) ───────────────
        // `taxEnabled` is immutable, so the dormant transfer-path check is a
        // bytecode constant (no SLOAD). Immutables must be assigned on EVERY
        // path, hence the explicit zero-out in the disabled branch.
        taxEnabled = tax_.enabled;
        if (tax_.enabled) {
            if (
                tax_.burnAddress == address(0) || tax_.canonicalHook == address(0)
                    || tax_.poolManager == address(0) || tax_.taxBpsMax > TAX_BPS_ABSOLUTE_MAX
                    || tax_.taxBps > tax_.taxBpsMax
            ) revert TaxConfigInvalid();

            taxBpsMax = tax_.taxBpsMax;
            taxBurnAddress = tax_.burnAddress;
            canonicalHook = tax_.canonicalHook;
            taxPoolManager = tax_.poolManager;
            canonicalPoolId = _computeCanonicalPoolId(
                tax_.pairedToken,
                tax_.canonicalPoolFee,
                tax_.canonicalTickSpacing,
                tax_.canonicalHook
            );
            taxBps = tax_.taxBps;
            _initTaxSets(tax_);

            emit TaxEnabled(
                canonicalPoolId, tax_.canonicalHook, tax_.taxBps, tax_.taxBpsMax, tax_.burnAddress
            );
        } else {
            taxBpsMax = 0;
            taxBurnAddress = address(0);
            canonicalHook = address(0);
            taxPoolManager = address(0);
            canonicalPoolId = bytes32(0);
        }

        _mint(msg.sender, maxSupply_);
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    /// @notice Burns `amount` tokens held by the caller.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /// @notice Burns `amount` tokens from `account`, debiting caller's allowance.
    function burnFrom(address account, uint256 amount) external {
        _spendAllowance(account, msg.sender, amount);
        _burn(account, amount);
    }

    // ─── Venue-scoped buy-side transfer tax ────────────────────────────────

    /// @notice Transfer override routing through the venue-scoped tax path.
    /// @dev Solady's `transfer`/`transferFrom` do NOT call the internal
    ///      `_transfer`; they inline the balance update. So the tax must be
    ///      applied by overriding the public entry points and re-dispatching to
    ///      `_transfer` for the actual moves. Allowance/Permit2 semantics are
    ///      preserved: `transferFrom` debits the FULL `amount` once via
    ///      `_spendAllowance` (which short-circuits the infinite Permit2
    ///      allowance), matching exactly what the caller signed for.
    function transfer(address to, uint256 amount) public override returns (bool) {
        _taxedTransfer(msg.sender, to, amount);
        return true;
    }

    /// @inheritdoc ERC20
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _taxedTransfer(from, to, amount);
        return true;
    }

    /// @dev The single chokepoint every PCT transfer flows through. Dormant
    ///      tokens short-circuit on the immutable `taxEnabled == false` (a
    ///      bytecode constant — no storage read) and behave exactly like
    ///      vanilla Solady ERC20.
    ///
    ///      When enabled, the tax fires ONLY when ALL hold:
    ///        - `taxBps != 0` (rate not zeroed by the admin),
    ///        - `_isTaxVenue(from)` (PCT is LEAVING a known venue — a buy or
    ///          pool outflow; NEVER an into-pool sell, which has a trader as
    ///          `from` and would revert the pool if skimmed),
    ///        - `to` is not on the exempt allowlist (PC adapters), and
    ///        - the venue→trader amount is not fully covered by the canonical
    ///          exemption budget the hook attested this tx.
    ///      That budget is drawn down on EVERY venue outflow — including ones to
    ///      exempt recipients — so budget a canonical buy attested to an exempt
    ///      recipient cannot survive in the tx for a later side-pool outflow.
    ///      The taxed slice is sent to the burn sink; the recipient receives
    ///      `amount - tax`. Two `Transfer` logs (net + skim) are emitted, plus
    ///      a `TaxApplied`. The `from` balance drops by exactly `amount`, so a
    ///      V2/V3/V4 pool's own outflow accounting is unaffected.
    function _taxedTransfer(address from, address to, uint256 amount) internal {
        if (taxEnabled) {
            uint16 bps = taxBps;
            if (bps != 0 && amount != 0 && _isTaxVenue(from)) {
                // Draw down the canonical-exemption budget on EVERY venue
                // outflow, including ones to exempt recipients. PCT bought from
                // the canonical pool by an exempt recipient (e.g. a
                // permissionless buy-and-burn, or the LP-fee locker) attests
                // budget; consuming it on that same outflow keeps the budget
                // from persisting in the tx for a later side-pool outflow to
                // harvest tax-free.
                uint256 exemptAmt = _consumeCanonicalBudget(amount);
                if (!_taxExempt[to]) {
                    uint256 taxable = amount - exemptAmt;
                    uint256 tax = (taxable * uint256(bps)) / TAX_DENOMINATOR;
                    if (tax != 0) {
                        // tax <= taxable <= amount, so `amount - tax` cannot underflow.
                        _transfer(from, to, amount - tax);
                        _transfer(from, taxBurnAddress, tax);
                        emit TaxApplied(from, to, amount, tax, amount - tax);
                        return;
                    }
                }
            }
        }
        _transfer(from, to, amount);
    }

    /// @dev Consume up to `amount` of the transient canonical-exemption budget
    ///      and return how much was exempted (amount-pinned). The budget is
    ///      fungible within a tx but bounded by total attested amount, so it
    ///      cannot over-exempt: it can subsidize a same-tx side-pool outflow,
    ///      but only up to the realized canonical PCT-out attested this tx.
    ///      That bound means it only benefits a buyer already concentrating
    ///      real volume on canonical, and a side / `initializePoolOpen` pool
    ///      can never earn budget, so burned tax proceeds are never a
    ///      bid-funding source.
    function _consumeCanonicalBudget(uint256 amount) private returns (uint256 exemptAmt) {
        uint256 b = _loadCanonicalBudget();
        if (b == 0) return 0;
        exemptAmt = b >= amount ? amount : b;
        _storeCanonicalBudget(b - exemptAmt);
    }

    function _loadCanonicalBudget() private view returns (uint256 b) {
        bytes32 slot = _CANONICAL_BUDGET_SLOT;
        /// @solidity memory-safe-assembly
        assembly {
            b := tload(slot)
        }
    }

    function _storeCanonicalBudget(uint256 b) private {
        bytes32 slot = _CANONICAL_BUDGET_SLOT;
        /// @solidity memory-safe-assembly
        assembly {
            tstore(slot, b)
        }
    }

    /// @inheritdoc IArtCoinsTaxable
    function attestCanonicalBudget(bytes32 poolId, uint256 amount) external override {
        if (msg.sender != canonicalHook) revert NotCanonicalHook();
        // Silently ignore attestations for any pool other than the single
        // factory-blessed canonical pool. Side / permissionless-open pools on
        // the same shared hook therefore never earn an exemption budget — and
        // this is a no-op rather than a revert so it can never brick a swap on
        // such a pool. (`canonicalHook != 0` ⇒ tax is enabled, since the ctor
        // only sets the hook in the enabled branch.)
        if (poolId != canonicalPoolId || amount == 0) return;
        uint256 b = _loadCanonicalBudget();
        unchecked {
            // Bounded by token supply across a tx; cannot realistically overflow.
            _storeCanonicalBudget(b + amount);
        }
    }

    /// @notice Update the buy-tax rate. Token-admin only (on PC the admin is
    ///         `TokenAdminPoker`, whose `setTokenTaxBps` enforces the two-key
    ///         carve-out so the rate stays tunable past the 1y admin lock).
    ///         Bounded `[0, taxBpsMax]` — can only lower or restore, never
    ///         exceed the parity cap.
    function setTaxBps(uint16 newBps) external {
        if (msg.sender != _admin) revert NotAdmin();
        if (!taxEnabled) revert TaxNotEnabled();
        if (newBps > taxBpsMax) revert TaxBpsTooHigh();
        uint16 old = taxBps;
        taxBps = newBps;
        emit TaxBpsUpdated(old, newBps);
    }

    /// @inheritdoc IArtCoinsTaxable
    function isTaxVenue(address account) external view override returns (bool) {
        return _isTaxVenue(account);
    }

    /// @inheritdoc IArtCoinsTaxable
    function isTaxExempt(address account) external view override returns (bool) {
        return _taxExempt[account];
    }

    /// @dev Hot-path venue check. The V4 PoolManager (the dominant venue,
    ///      covering every V4 pool) is an immutable compare; the V2/V3 set is a
    ///      single mapping read. Reached only when `taxEnabled` is true.
    function _isTaxVenue(address account) internal view returns (bool) {
        return account == taxPoolManager || _taxVenue[account];
    }

    /// @dev Mirror of V4 `PoolId.toId(PoolKey)` =
    ///      `keccak256(abi.encode(currency0, currency1, fee, tickSpacing, hooks))`.
    ///      A PoolKey of all static (value) types hashes identically whether
    ///      via the in-memory struct (`keccak256(poolKey, 0xa0)`) or
    ///      field-wise `abi.encode`. Computed from `address(this)` to avoid a
    ///      CREATE2 circular dependency; the canonical-buy fork test is the
    ///      live proof it matches the pool the factory actually creates.
    function _computeCanonicalPoolId(
        address pairedToken,
        uint24 fee,
        int24 tickSpacing,
        address hook
    ) private view returns (bytes32) {
        address self = address(this);
        (address c0, address c1) = self < pairedToken ? (self, pairedToken) : (pairedToken, self);
        return keccak256(abi.encode(c0, c1, fee, tickSpacing, hook));
    }

    /// @dev Populate the exempt allowlist and DERIVE the V2/V3 venue pool
    ///      addresses from `address(this)`. Storage writes are permitted in a
    ///      constructor-called helper (only immutables carry the
    ///      assign-in-constructor restriction). The venue set is frozen here
    ///      forever — there is intentionally no add/remove path.
    function _initTaxSets(TaxConfig memory tax_) private {
        uint256 e = tax_.exempt.length;
        for (uint256 i = 0; i < e; i++) {
            _taxExempt[tax_.exempt[i]] = true;
        }

        address self = address(this);
        uint256 v = tax_.venues.length;
        for (uint256 i = 0; i < v; i++) {
            TaxVenue memory ven = tax_.venues[i];
            (address t0, address t1) =
                self < ven.counterToken ? (self, ven.counterToken) : (ven.counterToken, self);
            address pool;
            if (ven.kind == 1) {
                // Uniswap-V2-style: salt = keccak256(abi.encodePacked(t0, t1)).
                pool = address(
                    uint160(
                        uint256(
                            keccak256(
                                abi.encodePacked(
                                    hex"ff",
                                    ven.factory,
                                    keccak256(abi.encodePacked(t0, t1)),
                                    ven.initCodeHash
                                )
                            )
                        )
                    )
                );
            } else if (ven.kind == 2) {
                // Uniswap-V3-style: salt = keccak256(abi.encode(t0, t1, fee)).
                pool = address(
                    uint160(
                        uint256(
                            keccak256(
                                abi.encodePacked(
                                    hex"ff",
                                    ven.factory,
                                    keccak256(abi.encode(t0, t1, ven.v3Fee)),
                                    ven.initCodeHash
                                )
                            )
                        )
                    )
                );
            } else {
                revert TaxConfigInvalid();
            }
            _taxVenue[pool] = true;
        }
    }

    /// @notice Transfers the admin role. Only callable by the current admin.
    /// @dev Reverts on zero address — to give up admin entirely, use `renounceAdmin`.
    /// @param admin_ The new admin address (must be non-zero).
    function updateAdmin(address admin_) external {
        if (msg.sender != _admin) revert NotAdmin();
        if (admin_ == address(0)) revert ZeroAddress();
        address oldAdmin = _admin;
        _admin = admin_;
        emit UpdateAdmin(oldAdmin, admin_);
    }

    /// @notice Permanently renounces admin authority over this token.
    /// @dev After this call, no further admin actions are possible:
    ///      no metadata updates and no renderer swaps.
    function renounceAdmin() external {
        if (msg.sender != _admin) revert NotAdmin();
        address oldAdmin = _admin;
        _admin = address(0);
        emit UpdateAdmin(oldAdmin, address(0));
        emit AdminRenounced(oldAdmin);
    }

    /// @notice Updates the token's image URL. Only callable by the admin.
    function updateImage(string memory image_) external {
        if (msg.sender != _admin) revert NotAdmin();
        _image = image_;
        emit UpdateImage(image_);
        emit ContractURIUpdated();
    }

    /// @notice Updates the token's metadata/description. Only callable by the admin.
    function updateMetadata(string memory metadata_) external {
        if (msg.sender != _admin) revert NotAdmin();
        _metadata = metadata_;
        emit UpdateMetadata(metadata_);
        emit ContractURIUpdated();
    }

    /// @notice Sets a metadata renderer contract to override the default contract URI.
    /// @dev Pass the zero address to fall back to the built-in default renderer.
    ///      A non-zero renderer must have contract code at the address — this
    ///      blocks the foot-gun of pointing at an EOA, which would make
    ///      `contractURI()` and `tokenURI()` revert until the admin resets.
    function setMetadataRenderer(address renderer_) external {
        if (msg.sender != _admin) revert NotAdmin();
        if (renderer_ != address(0) && renderer_.code.length == 0) revert InvalidRenderer();
        _metadataRenderer = renderer_;
        emit MetadataRendererUpdated(renderer_);
        emit ContractURIUpdated();
    }

    /// @notice One-time verification signal emitted by the original admin.
    function verify() external {
        if (msg.sender != _originalAdmin) revert NotOriginalAdmin();
        if (_verified) revert AlreadyVerified();
        _verified = true;
        emit Verified(msg.sender, address(this));
    }

    /// @notice Returns contract-level metadata per ERC-7572.
    function contractURI() external view returns (string memory) {
        return _resolveURI();
    }

    /// @notice Returns token metadata (same as contractURI).
    function tokenURI() external view returns (string memory) {
        return _resolveURI();
    }

    function _resolveURI() internal view returns (string memory) {
        if (_metadataRenderer != address(0)) {
            return IMetadataRenderer(_metadataRenderer).contractURI(address(this));
        }
        return _buildDefaultContractURI();
    }

    function _buildDefaultContractURI() internal view returns (string memory) {
        string memory json = string.concat(
            '{"name":"',
            LibString.escapeJSON(name()),
            '","symbol":"',
            LibString.escapeJSON(symbol()),
            '","description":"',
            LibString.escapeJSON(_metadata),
            '","image":"',
            LibString.escapeJSON(_image),
            '"}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    /// @notice Returns the current admin address.
    function admin() external view returns (address) {
        return _admin;
    }

    /// @notice Returns the original admin address (set at construction, never changes).
    function originalAdmin() external view returns (address) {
        return _originalAdmin;
    }

    /// @notice Returns the token's image URL.
    function imageUrl() external view returns (string memory) {
        return _image;
    }

    /// @notice Returns the token's metadata/description string.
    function metadata() external view returns (string memory) {
        return _metadata;
    }

    /// @notice Returns the freeform context string.
    function context() external view returns (string memory) {
        return _context;
    }

    /// @notice Returns the configured metadata renderer contract (zero if using default).
    function metadataRenderer() external view returns (address) {
        return _metadataRenderer;
    }

    /// @notice Returns whether this token has been verified by the original admin.
    function isVerified() external view returns (bool) {
        return _verified;
    }

    /// @notice ERC-165 introspection — supports ERC20 and ERC165.
    function supportsInterface(bytes4 _interfaceId) public pure returns (bool) {
        return _interfaceId == type(IERC20).interfaceId || _interfaceId == type(IERC165).interfaceId;
    }
}
