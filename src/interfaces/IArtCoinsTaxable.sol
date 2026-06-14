// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title  IArtCoinsTaxable — venue-scoped buy-side transfer-tax surface
/// @notice Shared types + the hook→token attestation interface for the
///         OPT-IN, default-off transfer tax on `ArtCoinsToken`. Every art coin
///         carries the dormant code; only a deploy that passes
///         `TaxConfig.enabled = true` (currently only PERMANENT COLLECTION's
///         111PUNKS) switches it on.
///
/// @dev    The tax is scoped to DEX *buys / pool outflows*: it fires only when
///         the transfer SENDER is a known trading venue and the recipient is
///         not an allowlisted protocol contract. It never fires on transfers
///         INTO a venue (sells / LP seeding — those would revert the pool), on
///         wallet-to-wallet sends, or on lending / bridge / CEX flows. The
///         canonical (factory-blessed) pool is exempted via an amount-pinned
///         transient budget the canonical hook attests per swap.
interface IArtCoinsTaxable {
    /// @notice The canonical hook attests the exact PCT amount a canonical
    ///         buy (or canonical LP removal) moves OUT of the V4 PoolManager,
    ///         so the token can exempt exactly that much of the venue→trader
    ///         transfer that follows later in the same tx.
    /// @dev    MUST be called only by the immutable `canonicalHook`. The token
    ///         silently ignores attestations whose `poolId` is not the single
    ///         canonical pool id pinned at construction — so a side / open pool
    ///         on the same shared hook can never earn an exemption budget. The
    ///         budget lives in EIP-1153 transient storage: it accumulates
    ///         within a tx and auto-clears at tx end. Amount-pinned (NOT a
    ///         boolean) and fungible within the tx: it CAN subsidize a same-tx
    ///         side-pool outflow, but only up to the realized canonical PCT-out
    ///         attested this tx (bounded). The exemption therefore only ever
    ///         benefits a buyer already concentrating real volume on canonical,
    ///         and a side / `initializePoolOpen` pool can never earn budget, so
    ///         burned tax proceeds are never a bid-funding source.
    /// @param  poolId The V4 pool id the attesting swap/removal acted on.
    /// @param  amount Realized PCT amount leaving the PoolManager to a trader/LP.
    function attestCanonicalBudget(bytes32 poolId, uint256 amount) external;

    /// @notice True once the tax feature is switched on (immutable at deploy).
    function taxEnabled() external view returns (bool);

    /// @notice Current buy-tax rate in bps (10_000 = 100%). Bounded `[0, taxBpsMax]`.
    function taxBps() external view returns (uint16);

    /// @notice Hard parity cap for `taxBps` (immutable). The bounded setter can
    ///         never raise the rate above this.
    function taxBpsMax() external view returns (uint16);

    /// @notice The single factory-blessed canonical pool id (immutable).
    function canonicalPoolId() external view returns (bytes32);

    /// @notice The canonical hook authorized to attest (immutable).
    function canonicalHook() external view returns (address);

    /// @notice Burn sink the tax skim is routed to (immutable, e.g. 0xdEaD).
    function taxBurnAddress() external view returns (address);

    /// @notice Whether `account` is a venue whose PCT outflows are taxed.
    function isTaxVenue(address account) external view returns (bool);

    /// @notice Whether `account` is an allowlisted recipient exempt from the tax.
    function isTaxExempt(address account) external view returns (bool);
}

/// @notice One precomputable trading venue. The V4 PoolManager is passed
///         separately as `TaxConfig.poolManager` (it covers every V4 pool with
///         one check); this struct enumerates the V2/V3-style pools, whose
///         addresses the token DERIVES from `address(this)` in its constructor
///         (the addresses depend on the token address, so they cannot be passed
///         in directly without a CREATE2 circular dependency).
struct TaxVenue {
    /// @dev 1 = Uniswap-V2-style CREATE2 pair; 2 = Uniswap-V3-style CREATE2 pool.
    uint8 kind;
    /// @dev The V2/V3 factory the pool is CREATE2-deployed by.
    address factory;
    /// @dev The factory's pair/pool init-code hash.
    bytes32 initCodeHash;
    /// @dev The counterparty token the PCT pool pairs against (e.g. WETH, USDC).
    address counterToken;
    /// @dev V3 fee tier (kind 2 only); ignored for kind 1.
    uint24 v3Fee;
}

/// @notice Full tax configuration consumed by `ArtCoinsToken`'s constructor.
///         Default-off: an all-zero / `enabled = false` value (the
///         `_emptyTaxConfig()` the standard deploy path passes) leaves the
///         token behaving exactly like a vanilla Solady ERC20, paying only one
///         immutable-bool short-circuit per transfer.
/// @dev    All fields are token-INDEPENDENT so they can be constructor args
///         without a CREATE2 circular dependency: the venue pool addresses and
///         the canonical pool id are DERIVED inside the constructor from
///         `address(this)` + these inputs.
struct TaxConfig {
    /// @dev Master switch. `false` ⇒ fully dormant.
    bool enabled;
    /// @dev Launch buy-tax rate in bps (10_000 = 100%). Must be `<= taxBpsMax`.
    uint16 taxBps;
    /// @dev Hard parity cap. The bounded setter can never exceed this; the
    ///      token additionally rejects any value above its own compile-time
    ///      `TAX_BPS_ABSOLUTE_MAX` so "never above parity" holds structurally.
    uint16 taxBpsMax;
    /// @dev Burn sink for the tax skim (e.g. 0xdEaD). Must be non-zero when enabled.
    address burnAddress;
    /// @dev V4 PoolManager singleton — the dominant venue (covers ALL V4 pools).
    address poolManager;
    /// @dev The factory-blessed canonical hook authorized to attest exemptions.
    address canonicalHook;
    /// @dev The token the canonical pool pairs against: `address(0)` = native ETH.
    ///      Used only to derive `canonicalPoolId`.
    address pairedToken;
    /// @dev The canonical pool's `fee` field (V4 dynamic-fee flag, 0x800000).
    uint24 canonicalPoolFee;
    /// @dev The canonical pool's tick spacing.
    int24 canonicalTickSpacing;
    /// @dev Recipients allowlisted on the `to` side (PC adapters that
    ///      legitimately receive PCT from a venue and must not be skimmed).
    address[] exempt;
    /// @dev Precomputable V2/V3 venues (derived from `address(this)` in ctor).
    TaxVenue[] venues;
}
