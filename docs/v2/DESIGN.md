# artcoins v2: design

status: architect draft for the build agents. scope: contracts, interfaces, constants, work breakdown. source of truth for v1 behavior is `src/` at commit `8f8c62a`. no `docs/v2/review/*.md` existed while this was written; reviewers should diff their findings against section 3 and file anything missing as a new open decision.

chain facts below were read with `cast call` against mainnet on 2026-10-06 (read only). everything else is from code.

| live fact | value |
|---|---|
| current factory 0x4959…4e0e | owner 0xCB43…17F9, deprecated, deployFee 0.069 eth, defaultProtocolFeeBps 2000, teamFeeRecipient 0xCB43…17F9 |
| current skim hook 0x636c…a9cc | factory 0x4959…, feeEscrow 0x7559…, extension allowlist 0xd6D5…e6E8, runtime 20,612 bytes, `initializePoolOpen` present (open pools enabled, cannot be disabled) |
| current locker 0x866e…6aab | keeperRewardBps 0, keeperRewardCap 0.01 eth, escrow 0x7559… |
| escrow 0x7559…25F2 | hook and locker are depositors, eth balance 0 |
| coin 111 0x61C9…B8ae | admin 0xA96a…6258, tax on, taxBps 1500, taxBpsMax 2000, tax sink 0xf5c3…8753 (a contract, not a burn address), supply 1.11e9, renderer 0x7604…eEc7 |
| 111 pool | eth/111, dynamic fee, tickSpacing 200, poolId 0xf860…f795, 111 is token1, 14 lp positions |
| 111 skim config | baseline 6000 (6% of volume), bountyBps 8333, maxReferral 250, lpFee 5000, bounty 0x8C72…CD01 (implements `streamForward`), protocol 0xed3E…ba9, referralPayout 0xB03C…9d4c, quote native eth |
| 111 locker split | one slot, 100% to 0xeBD9…A961 (a `FeeAutoSwapper`, endRecipient 0x8C72…, native, maxSlippage 500, minBlocks 50, maxStepIn 1e24), slot admin 0x…dEaD (recipient effectively frozen) |
| LAYER legacy hook 0xa5ea…28cc | factory 0xd159…, `protocolFeeNumerator` 0 (owner settable up to 50% of lp fee), open pools present |
| older factory 0xf051… | deprecated=false (open), deployFee 0, hook 0xAAd6… (open pools present) |
| size note | live skim hook runtime is 20,612 bytes. this source built with `FOUNDRY_PROFILE=ci` (runs 200, native solc 0.8.26) is 20,558 bytes, 4,018 bytes of headroom. the foundry.toml comment ("~24,547 bytes, 29 bytes headroom") is stale; the 24,578 figure in `foundry-out/` is the runs 20,000 default profile. the 54 byte gap to live means the live build is close but not identical to this source; the registry agent should settle provenance with a bytecode diff. |

## 1. component map v1 vs v2

v1 sources under `src/` stay frozen as the record of deployed bytecode. all v2 code lives under `src/v2/` plus `src/Constants.sol`.

| role | v1 (current stack, coin 111) | v2 | kind |
|---|---|---|---|
| constants | `SkimFeeConstants` (one value), literals duplicated per contract | `src/Constants.sol`, every v2 contract exposes `constantsHash()` and checks it at wiring | new |
| factory | `ArtCoinsFactory` owner + admins, 3 deploy entrypoints, protocol bps override public | `src/v2/ArtCoinsFactoryV2.sol`, single owner (Ownable2Step), one `deployToken(DeploymentConfigV2)`, owner only override | rewrite |
| deployer | `ArtCoinsDeployer`, salt = (tokenAdmin, salt) | `src/v2/utils/ArtCoinsDeployerV2.sol`, salt = (sender, configHash) | fix |
| token | `ArtCoinsToken`, venue tax, frozen venue set | `src/v2/ArtCoinsTokenV2.sol`, tax mode NONE / VENUE / HARD, add only venues, version tag, surfaced sink | rewrite |
| hook | `ArtCoinsHookSkimFee` on `ArtCoinsHook` base (sniper path, lp fee mev, open pools, extension swapping) | `src/v2/hooks/ArtCoinsHookV2.sol` hot path + `HookColdModule.sol` (immutable delegate), skim only | rewrite |
| static fee hook | `ArtCoinsHookStaticFee` | dropped | drop |
| locker | `ArtCoinsLpLocker`, slot admins can repoint recipients, deposits to escrow | `src/v2/lp-lockers/ArtCoinsLpLockerV2.sol`, recipients frozen, push with escrow fallback | modify |
| escrow | `ArtCoinsFeeEscrow`, add only depositors, permissionless claim | `src/v2/ArtCoinsFeeEscrowV2.sol`, core depositors, `selfClaimOnly` opt in, rescue of unowed excess | modify |
| delivery | inline per contract | `src/v2/libraries/FeeDelivery.sol` (internal lib) | new |
| mev | `ArtCoinsMevLinearSkim` (180m cap) + lp fee modules capped by hook at 15m | `src/v2/mev-modules/ArtCoinsMevLinearSkimV2.sol`, cap from Constants; lp fee modules not shipped | modify |
| fee swapper | `FeeAutoSwapper`, no owner, bookkeeping based flush | `src/v2/FeeAutoSwapperV2.sol`, owner tunables in bounds, balance based flush, rescue | modify |
| burn router | `BurnRouter` (weth, LAYER only), loopable clamp | `src/v2/protocol-fee/BurnRouterV2.sol`, native eth, one burn per block, reward on consumed | modify |
| protocol fee controller | `ProtocolFeeController`, immutable split | `src/v2/protocol-fee/ProtocolFeeControllerV2.sol`, owner split in bounds, rescue | modify |
| extension allowlist | `ArtCoinsPoolExtensionAllowlist` | reused contract, new instance, hook pointer owner settable | keep |
| renderers | `DynamicBlockRenderer`, `ExampleOnChainRenderer`, `LiquidityLayerSpriteRenderer` (raw svg text, quadratic concat) | `src/v2/renderer/*V2.sol` + `SvgText.sol` | fix |
| keepers | none | `src/v2/keepers/CollectFlushKeeperV1.sol` (coin 111, current stack), `ArtCoinsKeeperV2.sol` | new |
| version | none | `Constants.STACK_VERSION = 2` on token, hook pool registry, factory | new |

## 2. frozen vs owner mutable boundary

rule: per coin state is written once inside the launch tx and has no writer afterwards. owner powers on boundary contracts (hook, locker) are limited to global pointers, bounded global params, and rescue of balances that are not owed to anyone. the hook's cold module address is an immutable, so the owner cannot swap in code that rewrites per coin storage.

| contract | field | who can change | reason |
|---|---|---|---|
| token | name, symbol, supply, decimals, code | nobody | principle 1 |
| token | taxMode, taxBpsMax, taxSink, canonicalHook, canonicalPoolId, poolManager, exempt set | nobody (immutable or ctor only) | tax caps and sinks fixed at launch |
| token | taxBps within [0, taxBpsMax] | token admin | rate tuning under a frozen cap (111 relies on this) |
| token | venue set | venueAdmin, add only, renounceable | can only widen fee dodge coverage, never open a hole |
| token | metadata, image, renderer pointer, admin | token admin | cosmetic, as v1 |
| token | launcher, launcherVersion | nobody | integrator version tag |
| hook (per pool) | artCoinIsToken0, locker, mevModule, createdAt, skim config (lpFee, baselineSkimBps, bountyBps, maxReferralBpsOfVolume, bountyRecipient, protocolRecipient, referralPayout, quote), taxMode, extension, launcher, version | nobody | pool fee config and recipients fixed. v1 let the token admin change maxReferral, extension, sniper recipient: all removed |
| hook (global) | launchers allowlist | owner | factory side is replaceable; a new factory must be able to init pools |
| hook (global) | feeEscrow pointer | owner | escrow is replaceable; only affects where failed pushes land from now on |
| hook (global) | extensionAllowlist pointer | owner | affects new pools only (checked at init) |
| hook (global) | pushGas, preSwapStreamGas, preSwapStreamMin | owner, within Constants bounds | operational tuning; cannot zero out delivery (fallback catches everything) |
| hook | rescue eth, erc20, erc6909 claims | owner | hook holds nothing between swaps by invariant, so any balance is stray |
| hook | cold module address | nobody (immutable) | a mutable delegate would make every frozen field mutable |
| locker (per coin) | poolKey, positionIds, numPositions, rewardBps, rewardRecipients | nobody | lp lock and fee recipients fixed. slot admins removed |
| locker (per coin) | liquidity | nobody | no decrease path except zero liquidity fee collection |
| locker (global) | keeperRewardBps (<= 200), keeperRewardCap (0.001..0.05 eth) | owner | as v1 |
| locker (global) | feeEscrow pointer, launchers allowlist | owner | replaceable modules |
| locker | rescue eth, erc20 | owner | locker holds nothing between calls; no erc721 path exists |
| escrow | credited balances | nobody (owner cannot touch) | owed money |
| escrow | depositors | owner adds; removes only non core | removing hook or locker would brick their fallback |
| escrow | rescue of `balance minus totalOwed[token]` | owner | stray funds only |
| escrow | selfClaimOnly[feeOwner] | the feeOwner | fixes third party claim stranding |
| mev module | per pool decay config | nobody | set at init |
| factory | everything (fees, recipients, enabled modules, pause, protocol bps, minProtocolSkimShareBps, rescue) | owner | principle 2 |
| fee swapper | artCoin, poolKey, endRecipient | nobody | endRecipient is effectively a coin fee recipient (it sits in a frozen locker slot) |
| fee swapper | maxSlippageBps, minBlocksBetweenConverts, maxStepIn | owner, within Constants bounds | tuning |
| fee swapper | rescue of non paired, non artcoin tokens | owner | stray funds |
| burn router | coin, poolKey | nobody after init | |
| burn router | minProcessThreshold, maxImpactBps (bounded) | owner | tuning |
| protocol fee controller | treasury, burnRouter, split within MIN bounds, rescue | owner | protocol's own revenue |
| extension allowlist, renderers | all | owner | modules |

### 2.1 what the owner can still change on the old stacks (feeds the runbook)

| stack | contract | owner (0xCB43…) levers | effect on live coins | recommendation |
|---|---|---|---|---|
| current | factory 0x4959… | setDeprecated, setTeamFeeRecipient, setDefaultProtocolFeeBps, setDeployFee, setHook/Locker/MevModule/Extension, setAdmin, recoverETH, claimTeamFees | none on 111 (future deploys only) | keep deprecated; after v2 ships, `setHook(0x636c…, false)` |
| current | hook 0x636c… | none (no owner) | n/a | token admin of 111 can still call setMaxReferralBpsOfVolume (<= 1000), setPoolExtension, lockPoolExtension, setSniperFeeRecipient (inert for skim) |
| current | locker 0x866e… | setKeeperRewardBps (<= 2%), setKeeperRewardCap, withdrawETH, withdrawERC20 | keeper reward is taken from 111 fees | keep bps 0 or tiny; slot admin is 0x…dEaD so the 111 split is frozen |
| current | escrow 0x7559… | addDepositor (no remove) | none | do not add depositors |
| current | fee swapper 0xeBD9… | none | eth stranded by a third party `escrow.claim(swapper, 0)` is unrecoverable | run the collect and flush keeper (section 3, d8) |
| current | linear skim 0xb038… | none | | |
| older | factory 0xf051… | same setters | open to the public with zero fee on a superseded stack | `setDeprecated(true)` now |
| legacy | factory 0xd159… | same setters | | keep deprecated |
| legacy | hook 0xa5ea… | `setProtocolFeeNumerator` (factory owner) up to 50% of lp fee, taken to the factory | raises LAYER trading cost | leave at 0, document as the one live fee lever |
| legacy | `ArtCoinsLpLockerMultiple`, `ArtCoinsFeeLocker` | withdrawETH/ERC20 stray, addDepositor | slot admins may still repoint LAYER recipients | check who holds LAYER slot admins |
| legacy | LAYER burn router, protocol fee controller, LL extensions and renderer | thresholds, floors, sweeps, split, treasury, renderer strings | yes, LAYER flows | inventory in runbook |

## 3. changes

each block names the regression test. tests are fork tests against live v4 using `test/v2/harness/ForkBase.sol` and `ForkStack.sol`; file `test/v2/<Area>V2.fork.t.sol`.

### b1. tax exemption minted by add then remove liquidity
| item | design |
|---|---|
| contracts | `ArtCoinsHookV2`, `ArtCoinsTokenV2` |
| hook | `_beforeAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata p, bytes calldata)`: `tstore(keccak256(abi.encode(pid, sender, p.tickLower, p.tickUpper, p.salt)), 1)`. `_afterRemoveLiquidity`: skip any attestation or flow grant when that slot is set (position added in this tx). otherwise attest the art side delta (principal plus fees) |
| token | `_consumeCanonicalBudget` only when `from == poolManager`. v2/v3 venue outflows never draw budget |
| storage | transient only |
| invariant | exempt amount in a tx <= art coin that left the canonical pool from swaps plus positions that existed before the tx |
| tests | `test_tax_addThenRemoveSameTx_mintsNoBudget`, `test_tax_budgetNotSpendableOnV3Venue`, `test_tax_priorTxLpExit_isExempt`, `test_tax_lockerCollect_isExempt` |

### b2. recipient with no code or empty fallback bricks swaps
v1 `try IPreSwapStream(br).streamForward() {} catch {}` decodes the uint256 return outside the try: an eoa or empty fallback returns no data, decode reverts the swap (whenever the recipient holds >= 0.01 eth). separately, a bounty push failure reverts the swap.
| item | design |
|---|---|
| contract | `ArtCoinsHookV2` |
| function | `function _probeStream(address r) internal` : return if `r.code.length == 0` or `r.balance < preSwapStreamMin`; assembly `pop(call(preSwapStreamGas, r, 0, sel, 4, 0, 0))`. no returndata copy (no return bomb), no decode |
| storage | `HookGlobals { uint32 pushGas; uint32 preSwapStreamGas; uint96 preSwapStreamMin; address feeEscrow; address extensionAllowlist; }` one struct, owner set via cold module |
| events | `PreSwapStreamParamsSet(uint32 gas, uint96 min)` |
| invariant | no recipient behavior (no code, empty fallback, revert, gas burn, huge returndata) can revert a swap; probe cost <= preSwapStreamGas + 5k |
| tests | `test_swap_bountyEoaWithBalance_noRevert`, `test_swap_bountyEmptyFallback_noRevert`, `test_swap_bountyReturnBomb_bounded`, `test_swap_bountyGasBurner_bounded`, `test_swap_bountyRejectsEth_escrowed` |

### b3. skim charged on the unfilled part of a price limited swap
when the quote side is specified, `_beforeSwap` mints the skim S on the full abs(amountSpecified). a `sqrtPriceLimitX96` partial fill leaves the trader paying S on volume that never traded.
| item | design |
|---|---|
| contract | `ArtCoinsHookV2` |
| flow | `_beforeSwap` mints S claims and stores `tstore(SKIM_PENDING, S)`, `tstore(SKIM_REQUESTED, abs(amountToSwap))`. `_afterSwap` (quote specified branch) reads realized `R = abs(delta.quote)`; `fair = S * R / requested`; legs are split on `fair`; `over = S - fair` is burned, taken, and credited `feeEscrow.storeFeesNative{value: over}(sender)` where `sender` is the PoolManager caller |
| storage | accruals move from mappings (`accruedBounty`, `accruedProtocol`, `accruedReferral`) to transient slots. public `accruedReferral` getter is removed (always zero in v1) |
| events | `SkimRefunded(PoolId indexed poolId, address indexed to, uint256 amount)` |
| invariant | trader quote cost = realized + fair; fair + over = S; hook erc6909 balance is zero after every `_afterSwap` |
| tests | `test_skim_exactInPriceLimited_refundsUnfilled`, `test_skim_exactOutPriceLimited_refundsUnfilled`, `test_skim_fullFill_noRefund`, `test_burnRouterV2_claimsRefund` |

### b4. launch hijack
| item | design |
|---|---|
| contracts | `ArtCoinsFactoryV2`, `ArtCoinsDeployerV2` |
| functions | `function configHash(DeploymentConfigV2 calldata c) public pure returns (bytes32)` = `keccak256(abi.encode(c))`. `function predictToken(address sender, DeploymentConfigV2 calldata c) external view returns (address)`. deployer `deploy(TokenConfigV2 memory t, uint256 supply, TaxConfigV2 memory tax, bytes32 salt)` with `salt = keccak256(abi.encode(msg.sender, configHash(c)))` computed by the factory |
| also | `initializePoolOpen` removed (d3), so a predicted pool key cannot be pre initialized on the hook |
| invariant | token address is a function of (factory, sender, full config). a front runner with a different sender, or any different field, gets a different address and cannot block or capture the victim's launch |
| tests | `test_launch_frontrunCopiedConfig_differentAddress`, `test_launch_changedLockerConfig_differentAddress`, `test_launch_predictTokenMatches` |

### b5. fee swapper eth side fees strandable by third party escrow claim
`escrow.claim(feeOwner, token)` is permissionless; a third party pushes the swapper's eth to it, `flushPaired` then sees `availableFees == 0` and the eth has no exit. live 111 swapper 0xeBD9… is exposed (no sweep).
| item | design |
|---|---|
| contracts | `FeeAutoSwapperV2`, `ArtCoinsFeeEscrowV2` |
| swapper | `flushPaired()`: claim if escrowed > 0, then `pairedOut = pairedBalance()` (whole native or erc20 balance; the swapper holds no paired funds between calls by invariant). `convert` forwards `received` plus any paired balance |
| escrow | `mapping(address => bool) public selfClaimOnly; function setSelfClaimOnly(bool on) external` (msg.sender is the feeOwner). `claim` reverts `Unauthorized()` when `selfClaimOnly[feeOwner] && msg.sender != feeOwner`. swapper ctor calls `setSelfClaimOnly(true)` |
| events | `SelfClaimOnlySet(address indexed feeOwner, bool on)` |
| invariant | after any call, swapper paired balance is 0 |
| tests | `test_swapperV2_thirdPartyEscrowClaim_thenFlush_forwardsAll`, `test_escrowV2_selfClaimOnly_blocksThirdParty`, `test_swapperV1_111_thirdPartyClaim_strands` (documents the live exposure) |

### b6. burn router clamp loopable in one tx, keeper reward on whole balance
| item | design |
|---|---|
| contract | `BurnRouterV2` (native eth quote, any v2 coin, init once) |
| functions | `processBurn(uint256 minOut) returns (uint256 ethIn, uint256 burned)`, `processBurnOpenTab(uint256 minOut)`, `claimRefund()` (pulls b3 refunds from escrow) |
| storage | `uint64 lastBurnBlock`; `uint16 maxImpactBps` (owner, [25, 300]); `uint96 minProcessThreshold` |
| pacing | both paths revert `AlreadyBurnedThisBlock()` when `lastBurnBlock == block.number` |
| reward | budget = balance minus `maxReward(balance)` reserved; after the swap `reward = min(consumed * KEEPER_REWARD_BPS / BPS, KEEPER_REWARD_CAP)`; unreserved remainder stays |
| invariant | price impact per block <= maxImpactBps; reward <= bps of consumed |
| tests | `test_burnV2_secondCallSameBlock_reverts`, `test_burnV2_loopingContract_cannotExceedImpact`, `test_burnV2_partialFill_rewardOnConsumed` |

### b7. module duration limits disagree with the hook cap
v1: `ArtCoinsMevLinearFees` and `ArtCoinsMevLinearSkim` accept up to 180m; the base hook expires lp fee modules at 15m (`MAX_MEV_MODULE_DELAY`), so a 69m default fee schedule silently stops at 15m.
| item | design |
|---|---|
| contracts | `Constants`, `ArtCoinsMevLinearSkimV2`, `ArtCoinsHookV2` |
| rule | one window cap `Constants.MAX_MEV_WINDOW = 180 minutes`. module `initialize` reverts above it. hook treats the module as expired at `createdAt + MAX_MEV_WINDOW` for both the skim clamp and the add liquidity lock, whatever the module reports |
| scope | v2 ships skim modules only. lp fee modules (LinearFees, DescendingFees, SniperSteppedFees, TimeDelay) need `mevModuleSetFee`, which v2 removes; factory refuses them via `IArtCoinsMevSkim` interface check |
| wiring | factory `setMevModule` and hook `initializePool` require `module.constantsHash() == Constants.hash()` |
| tests | `test_mevV2_durationAboveCap_reverts`, `test_hookV2_lockEndsAtCapEvenIfModuleLies`, `test_constants_hashAgreesAcrossStack` |

### b8. renderer gas and unescaped svg text
| item | design |
|---|---|
| contracts | `src/v2/renderer/SvgText.sol`, `DynamicBlockRendererV2`, `ExampleOnChainRendererV2`, `SpriteRendererV2` |
| functions | `SvgText.text(string memory s, uint256 maxBytes) internal pure returns (string memory)`: utf8 safe truncate (never cuts a multibyte char) then `LibString.escapeHTML`. glyph layers built with solady `DynamicBufferLib` (linear, not quadratic `string.concat` in a loop); glyph count capped by `Constants.MAX_GLYPHS` |
| invariant | `contractURI` returns valid json with valid svg for any name or symbol bytes; worst case gas <= `Constants.RENDER_GAS_BUDGET` (8m) |
| tests | `test_renderV2_escapesAngleAndAmp`, `testFuzz_renderV2_validForArbitraryNames`, `test_renderV2_truncateNeverSplitsUtf8`, `test_renderV2_maxGlyphsUnderBudget` |

### d1. push to recipient, escrow on failure
| item | design |
|---|---|
| library | `FeeDelivery` (internal): `function sendNative(address escrow, address to, uint256 amount, uint256 gasCap) internal returns (bool pushed)`: `call{value: amount, gas: gasCap}("")`, on failure `IArtCoinsFeeEscrowV2(escrow).storeFeesNative{value: amount}(to)`. `function sendErc20(address escrow, address token, address to, uint256 amount) internal returns (bool pushed)`: low level `transfer` with success and return check, on failure approve and `storeFees` |
| users | hook (bounty, protocol, referral legs), locker (every slot, both currencies), FeeAutoSwapperV2, ProtocolFeeControllerV2 |
| referral | `IReferralPayoutForHook(referralPayout).notify{value: r, gas: pushGas}(referrer)`; on failure credit the referrer in escrow (v1 folded it into protocol) |
| events | hook `FeeDelivered(PoolId indexed poolId, uint8 indexed leg, address indexed to, uint256 amount, bool escrowed)` replaces `LegForwarded`; locker `RewardDelivered(address indexed token, address indexed currency, address indexed to, uint256 amount, bool escrowed)` |
| invariant | delivery never reverts its caller once the caller is a core depositor; every wei reaches `to` or `to`'s escrow balance |
| tests | `test_delivery_payable_pushed`, `test_delivery_reverting_escrowed`, `test_delivery_gasBurner_escrowed`, `test_lockerV2_collect_revertingRecipient_noRevert` |

### d2. two fee dodge modes selected at launch
`enum TaxMode { NONE, VENUE, HARD }` (uint8), immutable on the token, mirrored into the hook pool record at init (hook reads `token.taxMode()` and `token.canonicalHook() == address(this)`).

| item | VENUE (v1 model, hardened) | HARD (transient allowance) |
|---|---|---|
| what is taxed or blocked | coin leaving a venue (PoolManager or listed v2/v3 pool) to a non exempt recipient pays `taxBps` to `taxSink` | any coin transfer with `from == poolManager` or `to == poolManager` reverts unless covered by a same tx canonical allowance in that direction; any transfer touching a listed venue reverts |
| hook call | `attestCanonicalBudget(bytes32 poolId, uint256 outAmount)` from `_afterSwap` (buys) and `_afterRemoveLiquidity` | `grantCanonicalFlow(bytes32 poolId, uint256 outAmount, uint256 inAmount)` from `_afterSwap` (buy: out, sell: in), `_afterAddLiquidity` (in), `_afterRemoveLiquidity` (out) |
| token storage | transient `BUDGET_SLOT` | transient `FLOW_OUT_SLOT`, `FLOW_IN_SLOT`, cumulative per tx, consumed exactly |
| venue list | `_taxVenue` set, add only | same set, transfers to or from it revert |
| venue admin | `address public venueAdmin` (set at launch, default token admin); `addTaxVenue(address)`, `addDerivedTaxVenue(TaxVenue calldata)`, `renounceVenueAdmin()` | same |
| errors and events | `TaxVenueAdded(address indexed venue)`, `VenueAdminRenounced()` | `CanonicalFlowRequired(address from, address to, uint256 amount)`, `VenueTransferBlocked(address venue)` |
| known limits | none new | router must settle after the swap (v4 router, universal router, locker, fee swapper, burn router all do); erc6909 claims of the coin can still circulate inside the PoolManager on side pools but cannot exit as erc20 |
| tests | `test_venue_sideV3Buy_taxed`, `test_venue_addOnly_noRemovePath`, `test_venue_renounce_freezesList` | `test_hard_canonicalBuyAndSell_pass`, `test_hard_sideV4PoolTake_reverts`, `test_hard_sideV4PoolSettle_reverts`, `test_hard_v3VenueTransfer_reverts`, `test_hard_lockerCollect_pass`, `test_hard_feeSwapperConvert_pass`, `test_hard_launchLiquidityPlacement_pass`, `test_hard_prepaySettle_reverts` |

taker and exact amount binding: v4 picks the `take` recipient after the hook returns, so the hook cannot name the taker. v2 binds exemption to the source (PoolManager only, never v2/v3 venues), to the tx (transient), to the direction (hard mode), and to the realized delta amount (cumulative, never more than what the canonical pool moved in this tx). b1 removes the add then remove mint. that is the tightest binding v4 allows; see open decision 8.

### d3. no open pools, official pools distinguishable
| item | design |
|---|---|
| hook | `initializePoolOpen` removed. `_beforeInitialize` reverts unless the hook itself is initializing inside `initializePool` (transient flag). `struct PoolInfo { uint16 version; uint8 taxMode; uint40 createdAt; address launcher; }`, `function poolInfo(PoolId) external view returns (PoolInfo memory)`, `function isOfficialPool(PoolId) external view returns (bool)` (launcher != 0) |
| factory | `function isArtCoin(address token) external view returns (bool)`; `deploymentInfo(token)` returns `DeploymentInfoV2 { address token; address hook; address locker; address mevModule; PoolId poolId; uint16 version; uint40 launchedAt; address[] extensions; }` |
| tests | `test_hookV2_noOpenInit`, `test_hookV2_directPoolManagerInit_reverts`, `test_hookV2_poolInfo_matchesLaunch` |

### d4. sender in salt, full config in launch event, tax sink
b4 covers the salt. section 6 covers the event. tax sink: `TaxConfigV2.taxSink` must be `Constants.DEAD` or the pool's `bountyRecipient`, enforced by the factory, stored immutable on the token (`taxSink()`), echoed in `TaxEnabled` and `TokenCreatedV2`. 111's sink 0xf5c3… is an arbitrary contract today; v2 makes that choice explicit and limited. test `test_factoryV2_taxSinkOutsideAllowedSet_reverts`.

### d5. one constants file, checked at init
`src/Constants.sol` (section 4). every v2 contract has `function constantsHash() external pure returns (bytes32) { return Constants.hash(); }`. checks: factory `setHook`, `setLocker`, `setMevModule`, `setExtension`, `setEscrow`; hook `initializePool` checks locker and module; module `initialize` checks the hook; locker `placeLiquidity` checks the hook. a mismatch reverts `ConstantsMismatch(address module)`. constructor asserts cost no runtime bytes, so the hook may also assert in its constructor that `Hooks.validateHookPermissions` matches section 5. test `test_constants_mismatchedModule_rejected`.

### d6. version tag per pool
`Constants.STACK_VERSION = 2`. token: `function launcherVersion() external pure returns (uint16)`, `address public immutable launcher`. hook: `poolInfo(pid).version`. factory: `STACK_VERSION`, `DeploymentInfoV2.version`, event field. integrators check `hook.poolInfo(pid).version == 2 && factory.isArtCoin(token)`. test `test_versionTag_consistentAcrossTokenHookFactory`.

### d7. deployment hygiene
| item | design |
|---|---|
| one factory | `script/v2/DeployV2Stack.s.sol` deploys constants checked stack in one broadcast: escrow, extension allowlist, hook cold module, hook (mined salt, flags in section 5), locker, linear skim module, factory, fee delivery users (protocol fee controller, burn router), keeper. wires core depositors, launchers, enables modules, sets `deprecated = false` last |
| verify | `script/v2/verify-v2.sh` runs `forge verify-contract` for every address with profile `tune`, then a fork check that the on chain runtime equals the local build (fixes the provenance gap above) |
| superseded | registry json lists every stack with `status: active, superseded, deprecated`; owner txs: 0xf051 `setDeprecated(true)`; 0x4959 `setHook(0x636c…, false)` after v2 is live |
| tests | `test_deployV2Stack_wiringComplete`, `test_deployV2Stack_runtimeMatchesBuild` |

### d8. collect and flush keepers
| item | coin 111, current stack | generic v2 |
|---|---|---|
| contract | `src/v2/keepers/CollectFlushKeeperV1.sol` | `src/v2/keepers/ArtCoinsKeeperV2.sol` |
| immutables | `locker = 0x866e…`, `token = 0x61C9…`, `swapper = 0xeBD9…` (ctor args, pinned) | `factory` |
| entry | `function run(bool doConvert, uint256 minOut) external returns (uint256 flushed, uint256 converted)` | `function collectAndForward(address token, bool doConvert, uint256 minOut) external` |
| steps | 1 `locker.collectRewards(token)` (try). 2 `try swapper.flushPaired()`. 3 if `doConvert` `try swapper.convert(minOut)` (respects minBlocks 50). 4 forward the keeper's eth and coin balance to `msg.sender` | read `deploymentInfo(token).locker`, collect, then for each locker recipient that answers `supportsInterface(type(IFeeAutoSwapperV2).interfaceId)` flush and optionally convert; forward rewards |
| holds funds | never (`receive` then forward in the same call) | never |
| why | atomic collect then flush leaves no window between the locker's escrow deposit and the flush for a griefer's `escrow.claim(swapper, 0)` within normal mempool flow; it does not stop a griefer who acts between other txs | v2 delivery pushes, so flush is only needed after fallback deposits; convert remains needed for coin side fees |
| tests | `test_keeperV1_111_collectFlushConvert_fork`, `test_keeperV1_nothingToFlush_noRevert` | `test_keeperV2_collectAndForward_swapperRecipient` |

## 4. constants file

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// single source of truth for every cap shared by separately deployed v2 contracts.
library Constants {
    uint16 internal constant STACK_VERSION = 2;

    // denominators
    uint256 internal constant BPS = 10_000;
    uint256 internal constant SKIM_DENOMINATOR = 100_000;
    uint256 internal constant FEE_DENOMINATOR = 1_000_000;

    // hook and pool fee config (frozen per pool, validated at init)
    uint24 internal constant MAX_LP_FEE = 100_000; // 10% in 1e6
    uint24 internal constant MAX_SKIM_BPS = 90_000; // anti sniper ceiling, 90% of volume
    uint24 internal constant MAX_BASELINE_SKIM_BPS = 10_000; // 10% of volume
    uint24 internal constant MAX_REFERRAL_CAP_OF_VOLUME = 1_000; // 1% of volume
    uint16 internal constant MAX_BOUNTY_BPS = 9_999;

    // hook delivery (owner tunable within bounds)
    uint32 internal constant PUSH_GAS_MIN = 10_000;
    uint32 internal constant PUSH_GAS_DEFAULT = 50_000;
    uint32 internal constant PUSH_GAS_MAX = 150_000;
    uint32 internal constant STREAM_GAS_MIN = 30_000;
    uint32 internal constant STREAM_GAS_DEFAULT = 150_000;
    uint32 internal constant STREAM_GAS_MAX = 500_000;
    uint96 internal constant STREAM_MIN_BALANCE_DEFAULT = 0.01 ether;
    uint96 internal constant STREAM_MIN_BALANCE_MAX = 10 ether;

    // anti sniper window (module and hook agree)
    uint32 internal constant MIN_MEV_WINDOW = 1 minutes;
    uint32 internal constant DEFAULT_MEV_WINDOW = 69 minutes;
    uint32 internal constant MAX_MEV_WINDOW = 180 minutes;
    uint24 internal constant DEFAULT_START_SKIM_BPS = 68_690;

    // locker
    uint256 internal constant MAX_REWARD_PARTICIPANTS = 7;
    uint256 internal constant MAX_LP_POSITIONS = 14;
    uint256 internal constant LOCKER_KEEPER_BPS_MAX = 200;
    uint256 internal constant LOCKER_KEEPER_CAP_MIN = 0.001 ether;
    uint256 internal constant LOCKER_KEEPER_CAP_MAX = 0.05 ether;

    // factory
    uint256 internal constant DEFAULT_TOKEN_SUPPLY = 1_000_000_000e18;
    uint256 internal constant MIN_TOKEN_SUPPLY = 1e18;
    uint256 internal constant MAX_EXTENSIONS = 10;
    uint16 internal constant MAX_EXTENSION_BPS = 9_000;
    uint16 internal constant MAX_PROTOCOL_FEE_BPS = 3_000;
    uint256 internal constant MAX_DEPLOY_FEE = 1 ether;

    // token tax
    uint16 internal constant TAX_BPS_ABSOLUTE_MAX = 2_000;
    uint256 internal constant MAX_TAX_VENUES = 32;
    uint256 internal constant MAX_TAX_EXEMPT = 16;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // keepers, swapper, burn router
    uint256 internal constant KEEPER_REWARD_BPS = 50;
    uint256 internal constant KEEPER_REWARD_CAP = 0.01 ether;
    uint256 internal constant SPOT_FLOOR_BPS = 8_000;
    uint256 internal constant SWAPPER_SLIPPAGE_MIN = 50;
    uint256 internal constant SWAPPER_SLIPPAGE_MAX = 1_000;
    uint256 internal constant SWAPPER_MIN_BLOCKS_MIN = 1;
    uint256 internal constant SWAPPER_MIN_BLOCKS_MAX = 50_400;
    uint16 internal constant BURN_IMPACT_MIN = 25;
    uint16 internal constant BURN_IMPACT_DEFAULT = 100;
    uint16 internal constant BURN_IMPACT_MAX = 300;
    uint256 internal constant BURN_THRESHOLD_FLOOR = 0.001 ether;

    // protocol fee controller
    uint16 internal constant PFC_MIN_TREASURY_BPS = 4_000;
    uint16 internal constant PFC_MIN_BURN_BPS = 1_000;

    // renderers
    uint256 internal constant MAX_GLYPHS = 256;
    uint256 internal constant RENDER_GAS_BUDGET = 8_000_000;

    function hash() internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                STACK_VERSION, MAX_LP_FEE, MAX_SKIM_BPS, MAX_BASELINE_SKIM_BPS,
                MAX_REFERRAL_CAP_OF_VOLUME, MAX_MEV_WINDOW, MIN_MEV_WINDOW,
                MAX_REWARD_PARTICIPANTS, MAX_LP_POSITIONS, MAX_PROTOCOL_FEE_BPS,
                TAX_BPS_ABSOLUTE_MAX, KEEPER_REWARD_BPS, KEEPER_REWARD_CAP,
                PUSH_GAS_MIN, PUSH_GAS_MAX, STREAM_GAS_MIN, STREAM_GAS_MAX
            )
        );
    }
}
```

`hash()` covers every value that two separately deployed contracts must agree on. a test recomputes it from the literals so an edit without a hash bump fails ci.

## 5. hook address flags and bytecode size

| permission | v1 | v2 | why |
|---|---|---|---|
| beforeInitialize (1<<13) | yes | yes | reject foreign init |
| beforeAddLiquidity (1<<11) | yes | yes | mev lock, same tx position marker (b1) |
| afterAddLiquidity (1<<10) | no | yes | hard mode inflow allowance (d2) |
| afterRemoveLiquidity (1<<8) | yes | yes | exemption or outflow allowance |
| beforeSwap (1<<7) | yes | yes | skim on specified quote, stream probe |
| afterSwap (1<<6) | yes | yes | skim on unspecified quote, refund (b3), flow grant, delivery |
| beforeSwapReturnDelta (1<<3) | yes | yes | |
| afterSwapReturnDelta (1<<2) | yes | yes | |
| low 14 bits | 0x29CC (matches live 0x…a9cc) | 0x2DCC | mine with `HookMiner` against CREATE2 deployer 0x4e59…956C |

size plan. measured: v1 source `ArtCoinsHookSkimFee` is 20,558 bytes at the ci profile (runs 200), 4,018 bytes headroom; `SkimFeeInitLib` 943 bytes. the "29 bytes headroom" note in foundry.toml is stale and must be corrected by h1. so v2 fits even without the cold module, but the margin is thin once the additions land, and raising runs above 200 (cheaper swaps) needs room. v2 target: <= 20,000 bytes at runs 200; ci gate fails below 2,048 bytes headroom.

| lever | bytes (estimate, measured by package h1 before merge) |
|---|---|
| drop base hook surface the skim hook never needed: `initializePoolOpen`, `mevModuleSetFee`, `mevModuleSetSniperFee`, `mevModuleOperational`, sniper recipient set/lock/factorySet, 5 sniper getters, `weth` | minus 3,000 |
| freeze per pool fields: drop `setPoolExtension`, `lockPoolExtension`, `setMaxReferralBpsOfVolume`, `onlyTokenAdmin` (external `admin()` call inlined 6 times) | minus 1,300 |
| one attribution decoder instead of three external decode helpers; transient accruals instead of three mappings and a public getter | minus 600 |
| public constant getters replaced by one `constantsHash()` | minus 400 |
| drop the static fee variant: single concrete hook, no virtual `_setFee` / `_initializeFeeData` indirection | minus 200 |
| cold module: `fallback()` delegatecalls an immutable `HookColdModule` for `initializePool`, `initializeMevModule`, owner setters, rescue, `skimConfig`, `poolInfo`, ownership. hook keeps one dispatch stub. storage in an erc7201 namespaced struct shared by both (`HookStorage.layout()`) | minus 3,500 |
| additions: push with fallback, stream probe, partial fill refund, after add liquidity, flow grants, same tx position marker, launcher check | plus 2,700 |
| net | about minus 9,300 from 20,558, landing near 11,000 to 12,500 bytes, which leaves room to raise optimizer runs on the hot path |

rules for the cold module: address is a constructor immutable; it is never callable directly with effect (its functions check `address(this) == hook` via an immutable self check); view functions work under staticcall; the published `IArtCoinsHookV2` abi includes the cold selectors so explorers and integrators see one interface. if the module split slips, the first five rows plus the additions alone land near 17,000 bytes, still inside the gate.

## 6. launch config and event

```solidity
struct TokenConfigV2 {
    address tokenAdmin;
    string name;
    string symbol;
    bytes32 salt;          // vanity input, folded into configHash
    string image;
    string metadata;
    string context;
    uint256 totalSupply;   // 0 = default
    address renderer;
}
struct PoolConfigV2 {
    address hook;
    int24 tickIfToken0IsArtCoin;
    int24 tickSpacing;
    address extension;     // frozen per pool, 0 for none
    bytes extensionData;
}                          // paired currency is always native eth
struct FeeConfigV2 {
    uint24 lpFee;
    uint24 baselineSkimBps;
    uint16 bountyBps;      // factory enforces <= BPS minus minProtocolSkimShareBps
    uint24 maxReferralBpsOfVolume;
    address payable bountyRecipient;
}                          // protocolRecipient and referralPayout are injected by the factory
struct LockerConfigV2 {
    address locker;
    address[] rewardRecipients;  // project slots; factory appends the protocol slot
    uint16[] rewardBps;
    int24[] tickLower;
    int24[] tickUpper;
    uint16[] positionBps;
}
struct MevConfigV2 {
    address module;        // must be an IArtCoinsMevSkim with matching constantsHash
    uint24 startingSkimBps;
    uint32 windowSeconds;  // <= MAX_MEV_WINDOW
}
struct TaxConfigV2 {
    uint8 mode;            // 0 none, 1 venue, 2 hard
    uint16 taxBps;
    uint16 taxBpsMax;      // <= TAX_BPS_ABSOLUTE_MAX
    address taxSink;       // DEAD or bountyRecipient
    address venueAdmin;    // 0 = token admin
    address[] exempt;      // <= MAX_TAX_EXEMPT
    TaxVenue[] venues;     // derived v2/v3 pools, <= MAX_TAX_VENUES
}
struct ExtensionConfigV2 {
    address extension;
    uint256 msgValue;
    uint16 extensionBps;
    bytes extensionData;
}
struct DeploymentConfigV2 {
    TokenConfigV2 token;
    PoolConfigV2 pool;
    FeeConfigV2 fee;
    LockerConfigV2 locker;
    MevConfigV2 mev;
    TaxConfigV2 tax;
    ExtensionConfigV2[] extensions;
}

function deployToken(DeploymentConfigV2 calldata c) external payable returns (address token);
function deployTokenAsOwner(DeploymentConfigV2 calldata c, uint16 protocolBps) external payable returns (address token);

event TokenCreatedV2(
    address indexed sender,
    address indexed token,
    PoolId indexed poolId,
    uint16 stackVersion,
    bytes32 configHash,
    address protocolRecipient,
    address referralPayout,
    uint16 protocolBps,
    uint256 poolSupply,
    uint256 extensionsSupply,
    DeploymentConfigV2 config
);
```

notes: the whole config is emitted, so an indexer can rebuild every frozen field from one log. `deployTokenAsOwner` is the only path that overrides protocol bps (v1 let any caller pass 0 on an open factory).

## 7. credits engine coin: interface changes

the treasury is the fee recipient. it may or may not implement `IPreSwapStream`, may have a payable fallback, and must work with eth.

| surface | v1 behavior | v2 behavior | treasury needs |
|---|---|---|---|
| `IPreSwapStream.streamForward()` probe | high level call, all gas, return decoded outside try: eoa or empty fallback with >= 0.01 eth bricks swaps | low level, gas capped (`preSwapStreamGas`), return ignored, only if code and balance >= `preSwapStreamMin` | optional. if implemented: finish under the gas cap, never touch the PoolManager, no reliance on the return value |
| bounty leg | push all gas, revert swap on failure | push with `pushGas`, escrow on failure, `FeeDelivered` event | `receive` or payable fallback under `pushGas` (default 50k). otherwise funds sit in escrow under the treasury |
| escrow fallback | n/a | `claim(treasury, address(0))` permissionless unless the treasury opts into `selfClaimOnly` | nothing if its fallback is payable; anyone can push the balance. a treasury that cannot receive plain eth must call `claimTo` itself |
| locker rewards | escrow deposit, pull | push with fallback, both currencies | eth via plain transfer. coin side arrives as erc20 with no callback; to receive only eth, put a `FeeAutoSwapperV2` (endRecipient = treasury) in that slot |
| weth | lp side paid weth on weth pools | v2 pools are native eth only, nothing pays weth | wrap itself if it wants weth |
| protocol and referral legs | deployer chosen | factory injected | none |
| tax proceeds | arbitrary sink | `taxSink` is DEAD or the bounty recipient | if the treasury is the sink it receives the coin by erc20 transfer |
| hookData | `PoolSwapData{mevModuleSwapData, poolExtensionSwapData = abi.encode(PCSwapData)}` | unchanged | none |
| version and discovery | none | `hook.poolInfo(pid)`, `factory.deploymentInfo(token)`, `token.launcherVersion()` | none |
| accounting | `LegForwarded` | `FeeDelivered`, `RewardDelivered`, `SkimRefunded` | index these, no callback (open decision 15) |

## 8. work breakdown

v1 files are read only for every package. each package owns its files and its fork tests.

| pkg | owner files | depends on | deliverable |
|---|---|---|---|
| a0 constants and interfaces | `src/Constants.sol`, `src/v2/interfaces/*` (`IArtCoinsHookV2`, `IArtCoinsTokenV2`, `IArtCoinsFactoryV2` with section 6 structs, `IArtCoinsLpLockerV2`, `IArtCoinsFeeEscrowV2`, `IFeeAutoSwapperV2`, `IConstantsBound`), `test/v2/ConstantsV2.t.sol` | none | lands first, frozen after review |
| t1 token and deployer | `src/v2/ArtCoinsTokenV2.sol`, `src/v2/utils/ArtCoinsDeployerV2.sol`, `test/v2/TokenV2*.fork.t.sol` | a0 | b1 token half, d2 token, d4, d6 |
| h1 hook | `src/v2/hooks/ArtCoinsHookV2.sol`, `HookColdModule.sol`, `HookStorage.sol`, `test/v2/HookV2*.fork.t.sol`, size gate in `foundry.toml` ci profile comment | a0, t1 interface | b1 hook half, b2, b3, b7 hook half, d1 hook, d2 hook, d3, section 5 measured |
| l1 locker, escrow, delivery | `src/v2/lp-lockers/ArtCoinsLpLockerV2.sol`, `src/v2/ArtCoinsFeeEscrowV2.sol`, `src/v2/libraries/FeeDelivery.sol`, `test/v2/LockerV2*.fork.t.sol`, `test/v2/EscrowV2*.fork.t.sol` | a0 | b5 escrow half, d1 |
| m1 mev | `src/v2/mev-modules/ArtCoinsMevLinearSkimV2.sol`, tests | a0 | b7 module half |
| p1 periphery | `src/v2/FeeAutoSwapperV2.sol`, `src/v2/protocol-fee/BurnRouterV2.sol`, `src/v2/protocol-fee/ProtocolFeeControllerV2.sol`, tests | a0, l1 (FeeDelivery) | b5 swapper half, b6 |
| k1 keepers | `src/v2/keepers/*`, `test/v2/KeeperV1_111.fork.t.sol`, `test/v2/KeeperV2.fork.t.sol` | a0 (v1 keeper has no v2 deps, can ship first) | d8 |
| r1 renderers | `src/v2/renderer/*`, tests | a0 | b8 |
| f1 factory | `src/v2/ArtCoinsFactoryV2.sol`, `test/v2/FactoryV2*.fork.t.sol` | a0, t1, h1, l1, m1 | b4, d3 factory half, d4, section 6 |
| s1 deploy | `script/v2/DeployV2Stack.s.sol`, `script/v2/verify-v2.sh`, `test/v2/DeployV2Stack.fork.t.sol`, `test/v2/harness/ForkStack.sol` additions | all contracts | d7 |
| i1 integration | `test/v2/IntegrationV2.fork.t.sol` (credits engine style treasury mocks: no code, empty fallback, reverting, gas burner, IPreSwapStream good and bad) | s1 | end to end launch, swaps, collect, keeper, both tax modes |
| u1 ui and scripts | `ui/src/lib/encode.ts`, `ui/src/lib/abi.ts`, `ui/src/lib/config.ts`, `script-js/*` | a0, s1 | v2 config encoding (ui still encodes the static fee pool data today) |

integration order: a0, then t1 h1 l1 m1 p1 k1 r1 in parallel (k1 v1 helper may deploy independently on the current stack), then f1, then s1, then i1, then u1. h1 owns the size number; f1 may not merge until h1's ci size gate passes.

## 9. open decisions (recommendation first)

| # | decision | recommendation | alternative |
|---|---|---|---|
| 1 | locker reward recipients after launch | frozen, slot admins removed | keep slot admins (v1) |
| 2 | pool extension after launch | frozen at launch | token admin swap and lock (v1) |
| 3 | referral cap after launch | frozen | token admin within 1% (v1) |
| 4 | tax rate | token admin within frozen cap | frozen rate |
| 5 | who adds venues | `venueAdmin` set at launch (default token admin), add only, renounceable | launcher owner via registry read by the token (makes the token depend on mutable state) |
| 6 | tax sink | DEAD or bountyRecipient only | any address, surfaced in event |
| 7 | partial fill over skim | refund to the PoolManager caller via escrow | revert partial fills on quote specified swaps (breaks price limited burners) |
| 8 | taker binding | source, tx, direction, cumulative realized amount (true taker binding is impossible in v4) | require a recipient in hookData (breaks aggregators) |
| 9 | escrow third party claim | permissionless with `selfClaimOnly` opt in | self claim only for contracts (strands treasuries that cannot call out) |
| 10 | hook size strategy | immutable cold module via fallback | per function delegate stubs, or runs 100 |
| 11 | baseline skim cap | 10% of volume (111 uses 6%) | keep 90% |
| 12 | referral leg failure | credit the referrer in escrow | fold into protocol (v1) |
| 13 | weth paired pools | native eth only | allow weth |
| 14 | stream probe gas default | 150k, owner bounds 30k..500k; measure 0x8C72 `streamForward` gas on a fork before freezing | uncapped (v1) |
| 15 | fee receiver callback | none, events only | erc165 opt in callback |
| 16 | owner key handling | Ownable2Step on every owned v2 contract | plain Ownable |
| 17 | LAYER legacy `protocolFeeNumerator` | leave 0, document | none (cannot be removed) |
| 18 | hard mode erc6909 residual | accept and document | block via extra hook logic on other pools (impossible) |
| 19 | escrow depositor removal | core depositors (hook, locker) cannot be removed | free removal (can brick fallback) |
| 20 | v1 lp fee mev modules | not shipped in v2 | port them with a hook fee path (costs size) |
| 21 | push gas default | 50k (v1 forward gas was 35k) | 35k |
