# t1 notes: ArtCoinsTokenV2, ArtCoinsDeployerV2, TaxVenues

| item | behavior |
|---|---|
| modes | NONE plain erc20. VENUE: coin leaving the PoolManager or a listed venue to a non exempt recipient pays taxBps to taxSink; PoolManager outflow exempt up to the hook attested budget. HARD: PoolManager in/out consumes a same tx per direction grant from the canonical hook, exactly; listed venue transfers revert |
| D34 netting | `grantCanonicalFlow`: HARD out cancels unused in and in cancels unused out, so at most one direction is outstanding. VENUE: `inAmount` cancels unused budget, `outAmount` ignored. closes round trip, remove then re add, add then remove. the hook must report canonical inflows in VENUE too (`grantCanonicalFlow(pid, 0, in)` on sells and lp adds) |
| b1 token half | budget drawn only when `from == poolManager`, also on outflows to exempt recipients, so budget cannot outlive the canonical take. listed v2/v3 venue outflows taxed in full, never draw budget |
| frozen | mode, taxBpsMax, taxSink, canonicalHook, canonicalPoolId (eth/coin, dynamic fee, factory tickSpacing), poolManager, launcher, exempt set |
| sink | VENUE: DEAD or bountyRecipient. HARD: 0, DEAD or bountyRecipient (unused). NONE: 0 |
| exempt | VENUE only, <= MAX_TAX_EXEMPT, unique, contracts only (an eoa cannot be exempt, FT-07), not the token |
| venues | add only, <= MAX_TAX_VENUES, venueAdmin (default token admin) renounceable. `addTaxVenue` needs a contract that reports the coin as token0/token1; derived venues are CREATE2 hashes. PoolManager, hook, launcher, token refused |
| rate | token admin, VENUE only, <= taxBpsMax |
| votes | no ERC20Votes, no delegate, no checkpoints |
| strings (D30) | name 64, symbol 16, image 2048, metadata 4096, context 4096 bytes, at construction and in updateImage / updateMetadata. `StringTooLong(uint8 field, uint256 len)`, field 0 name, 1 symbol, 2 image, 3 metadata, 4 context. caps exposed as `MAX_*_BYTES` constants on the token |
| json | default contractURI escapes name, symbol, description, image with escapeJSON; renderer output is the renderer's job |
| deployer | CREATE2, factory supplied salt `keccak256(abi.encode(sender, configHash))`, factory only, launcher must be the factory, `predict` hashes the same initcode |

## residuals (documented, not fixed)
| item | why |
|---|---|
| HARD: coin claims (erc6909) can circulate on side pools inside the PoolManager | D24, cannot exit as erc20 |
| HARD: an unused out grant from a canonical buy settled as claims (no opposite canonical flow) can cover a side pool take later in the same tx, up to the canonical amount | per tx binding (D12); exits stay bounded by net canonical flow |
| a router that settles and takes the same coin gross (not net) after opposite canonical flows in one unlock reverts in HARD | D34 netting leaves only the net allowance; v4 routers settle net deltas |
| HARD: prepay style settle (transfer before the swap) reverts | design known limit, routers settle after |
| HARD: listing a venue freezes coin inside it (lp included) | by design, venue admin is the deployer's choice |
| FT-05 image and metadata remain admin mutable | DESIGN section 2 keeps them cosmetic and admin owned; interface is frozen |

## sizes (ci profile, runs 200)
| contract | runtime | initcode |
|---|---|---|
| ArtCoinsTokenV2 | 12,363 | 17,937 |
| ArtCoinsDeployerV2 | 20,838 | 20,991 |

the factory embeds the deployer initcode (about 21k) in its own initcode via `new ArtCoinsDeployerV2`; the factory initcode must stay under the 49,152 byte EIP-3860 limit.
