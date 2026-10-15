# artcoins v2: design

status: architect draft for the build agents. scope: contracts, interfaces, constants, work breakdown. source of truth for v1 behavior is `src/` at commit `8f8c62a`. no `docs/v2/review/*.md` existed while this was written; reviewers should diff their findings against section 3 and file anything missing as a new open decision.

D92 (2026-10-14) supersedes the parts of this draft that describe the fee swapper, the v2 keeper, locker rewards, the pool lp fee, `deployTokenAsOwner`, protocol bps, `pinned`, `lockAllowlist` and `lockRecipients`. the current shape is in docs/v2/DECISIONS.md D92 and `src/v2`.

sections 5 and 8 record the draft's hook split into a hot contract and a cold module. the shipped hook is the single contract `src/v2/hooks/ArtCoinsHookV2.sol`.

section 3 block ids are stable references from tests and reviews. ids b1 and d8 are retired, and the remaining ids keep their numbers. d2 describes the launch restriction.

chain facts below were read with `cast call` against mainnet on 2026-10-06 (read only). everything else is from code.

| live fact | value |
|---|---|
| current factory 0x4959…4e0e | owner 0xCB43…17F9, deprecated, deployFee 0.069 eth, default protocol fee 2000 bps, teamFeeRecipient 0xCB43…17F9 |
| current skim hook 0x636c…a9cc | factory 0x4959…, feeEscrow 0x7559…, extension allowlist 0xd6D5…e6E8, runtime 20,612 bytes, `initializePoolOpen` present (open pools enabled, cannot be disabled) |
| current locker 0x866e…6aab | keeper reward 0 bps, keeper reward cap 0.01 eth, escrow 0x7559… |
| escrow 0x7559…25F2 | hook and locker are depositors, eth balance 0 |
| coin 111 0x61C9…B8ae | admin 0xA96a…6258, supply 1.11e9, renderer 0x7604…eEc7 |
| 111 pool | eth/111, dynamic fee, tickSpacing 200, poolId 0xf860…f795, 111 is token1, 14 lp positions |
| 111 skim config | baseline 6000 (6% of volume), bountyBps 8333, maxReferral 250, lpFee 5000, bounty 0x8C72…CD01 (implements `streamForward`), protocol 0xed3E…ba9, referralPayout 0xB03C…9d4c, quote native eth |
| 111 locker split | one slot, 100% to 0xeBD9…A961 (a v1 fee converter contract, endRecipient 0x8C72…, native, maxSlippage 500, minBlocks 50, maxStepIn 1e24), slot admin 0x…dEaD (recipient effectively frozen) |
| LAYER legacy hook 0xa5ea…28cc | factory 0xd159…, `protocolFeeNumerator` 0 (owner settable up to 50% of lp fee), open pools present |
| older factory 0xf051… | deprecated=false (open), deployFee 0, hook 0xAAd6… (open pools present) |
| size note | live skim hook runtime is 20,612 bytes. this source built with `FOUNDRY_PROFILE=ci` (runs 200, native solc 0.8.26) is 20,558 bytes, 4,018 bytes of headroom. the foundry.toml comment ("~24,547 bytes, 29 bytes headroom") is stale; the 24,578 figure in `foundry-out/` is the runs 20,000 default profile. the 54 byte gap to live means the live build is close but not identical to this source; the registry agent should settle provenance with a bytecode diff. |

## 1. component map v1 vs v2

v1 sources under `src/` stay frozen as the record of deployed bytecode. all v2 code lives under `src/v2/` plus `src/Constants.sol`.

| role | v1 (current stack, coin 111) | v2 | kind |
|---|---|---|---|
| constants | `SkimFeeConstants` (one value), literals duplicated per contract | `src/Constants.sol`, every v2 contract exposes `constantsHash()` and checks it at wiring | new |
| factory | `ArtCoinsFactory` owner + admins, 3 deploy entrypoints, protocol bps override public | `src/v2/ArtCoinsFactoryV2.sol`, single owner (Ownable2Step), one `deployToken(DeploymentConfigV2)`, the owner calls it while `deprecated` | rewrite |
| deployer | `ArtCoinsDeployer`, salt = (tokenAdmin, salt) | `src/v2/utils/ArtCoinsDeployerV2.sol`, salt = (sender, configHash) | fix |
| token | `ArtCoinsToken`, v1 transfer fee on venue outflows, frozen venue set | `src/v2/ArtCoinsTokenV2.sol`, optional either-side transfer allowlist with a transient PoolManager allowance, version tag | rewrite |
| hook | `ArtCoinsHookSkimFee` on `ArtCoinsHook` base (sniper path, lp fee mev, open pools, extension swapping) | `src/v2/hooks/ArtCoinsHookV2.sol`, one contract, skim only | rewrite |
| static fee hook | `ArtCoinsHookStaticFee` | dropped | drop |
| locker | `ArtCoinsLpLocker`, slot admins can repoint recipients, deposits to escrow | `src/v2/lp-lockers/ArtCoinsLpLockerV2.sol`, pure lock (D92): holds the position NFTs, no fee collection | modify |
| escrow | `ArtCoinsFeeEscrow`, add only depositors, permissionless claim | `src/v2/ArtCoinsFeeEscrowV2.sol`, core depositors, `selfClaimOnly` opt in, rescue of unowed excess | modify |
| delivery | inline per contract | `src/v2/libraries/FeeDelivery.sol` (internal lib) | new |
| mev | `ArtCoinsMevLinearSkim` (180m cap) + lp fee modules capped by hook at 15m | `src/v2/mev-modules/ArtCoinsMevLinearSkimV2.sol`, cap from Constants; lp fee modules not shipped | modify |
| burn router | `BurnRouter` (weth, LAYER only), loopable clamp | `src/v2/protocol-fee/BurnRouterV2.sol`, native eth, one burn per block, reward on consumed | modify |
| protocol fee controller | `ProtocolFeeController`, immutable split | `src/v2/protocol-fee/ProtocolFeeControllerV2.sol`, owner split in bounds, rescue | modify |
| extension allowlist | `ArtCoinsPoolExtensionAllowlist` | reused contract, new instance, hook pointer owner settable | keep |
| renderers | `DynamicBlockRenderer`, `ExampleOnChainRenderer`, `LiquidityLayerSpriteRenderer` (raw svg text, quadratic concat) | `src/v2/renderer/*V2.sol` + `SvgText.sol` | fix |
| version | none | `Constants.STACK_VERSION = 2` on token, hook pool registry, factory | new |

## 2. frozen vs owner mutable boundary

rule: per coin state is written once inside the launch tx and has no writer afterwards. owner powers on boundary contracts (hook, locker) are limited to global pointers, bounded global params, and rescue of balances that are not owed to anyone. the hook is one contract with no delegate module, so no owner setter can replace the code that writes per coin storage.

| contract | field | who can change | reason |
|---|---|---|---|
| token | name, symbol, supply, decimals, code | nobody | principle 1 |
| token | canonicalHook, canonicalPoolId, poolManager, launcher, name, symbol | nobody (immutable) | the allowance source and the PoolManager are fixed at launch |
| token | allowlist entries (`setAllowed`), restriction switch (`unrestrict`, one way) | token admin until `lock()` or renounce | the admin edits every entry, including the seeded locker and extensions. the PoolManager and the canonical hook are rejected (`AllowedForbidden`) |
| token | `lock()` | token admin, once | freezes `setAllowed`, `unrestrict` and the hook's coin admin setters |
| token | metadata, image, renderer pointer, admin | token admin | cosmetic, as v1 |
| token | launcher, launcherVersion | nobody | integrator version tag |
| hook (per pool) | token, locker, mevModule, createdAt, bountyBps, protocolRecipient, restricted, launcher, version | nobody | the bounty share and the protocol recipient are fixed at launch. the pool lp fee is 0 (D92) |
| hook (per pool) | baselineSkimBps | coin admin, lower only, until `lock()` or renounce (D91) | `lowerBaselineSkim` |
| hook (per pool) | referralBps | coin admin, 0 to 100 bps of volume, until `lock()` or renounce (D98) | `setReferralBps`; default 0 (off); paid out of the protocol leg to the referrer named in hookData |
| hook (per pool) | extension | coin admin, until `lock()` or renounce (D88) | `setPoolExtension` |
| hook (per pool) | bountyRecipient | coin admin, until the coin is locked (`lock()`) or the admin renounced (D76) | the coin admin moves its own recipient; the rejected set mirrors the factory launch checks |
| hook (global) | launchers allowlist | owner | factory side is replaceable; a new factory must be able to init pools |
| hook (global) | feeEscrow pointer | owner | escrow is replaceable; only affects where failed pushes land from now on |
| hook (global) | extensionAllowlist pointer | owner | affects new pools only (checked at init) |
| hook | rescue eth, erc20, erc6909 claims | owner | hook holds nothing between swaps by invariant, so any balance is stray |
| locker (per coin) | poolKey, positionId, numPositions | nobody | lp lock |
| locker (per coin) | liquidity | nobody | no decrease path |
| locker (global) | launchers allowlist | owner | replaceable modules |
| locker | rescue eth, erc20 | owner | locker holds nothing between calls; no erc721 path exists |
| escrow | credited balances | nobody (owner cannot touch) | owed money |
| escrow | depositors | owner adds; removes only non core | removing hook or locker would brick their fallback |
| escrow | rescue of `balance minus totalOwed[token]` | owner | stray funds only |
| escrow | selfClaimOnly[feeOwner] | the feeOwner | fixes third party claim stranding |
| mev module | per pool decay config | nobody | set at init |
| factory | everything (fees, recipients, enabled modules, pause, rescue) | owner | principle 2 |
| burn router | coin, poolKey | nobody after init | |
| burn router | minProcessThreshold, maxImpactBps (bounded) | owner | tuning |
| protocol fee controller | treasury, burnRouter, split within MIN bounds, rescue | owner | protocol's own revenue |
| extension allowlist, renderers | all | owner | modules |

### 2.1 what the owner can still change on the old stacks (feeds the runbook)

| stack | contract | owner (0xCB43…) levers | effect on live coins | recommendation |
|---|---|---|---|---|
| current | factory 0x4959… | setDeprecated, setTeamFeeRecipient, setDefaultProtocolFeeBps, setDeployFee, setHook/Locker/MevModule/Extension, setAdmin, recoverETH, claimTeamFees | none on 111 (future deploys only) | keep deprecated; after v2 ships, `setHook(0x636c…, false)` |
| current | hook 0x636c… | none (no owner) | n/a | token admin of 111 can still call setMaxReferralBpsOfVolume (<= 1000), setPoolExtension, lockPoolExtension, setSniperFeeRecipient (inert for skim) |
| current | locker 0x866e… | keeper reward bps setter (<= 2%), keeper reward cap setter, withdrawETH, withdrawERC20 | keeper reward is taken from 111 fees | keep bps 0 or tiny; slot admin is 0x…dEaD so the 111 split is frozen |
| current | escrow 0x7559… | addDepositor (no remove) | none | do not add depositors |
| current | 111 fee converter 0xeBD9… | none | eth credited to it by a third party `escrow.claim(converter, 0)` is unrecoverable | none; the exposure is recorded in the runbook (section 3, b5) |
| current | linear skim 0xb038… | none | | |
| older | factory 0xf051… | same setters | open to the public with zero fee on a superseded stack | `setDeprecated(true)` now |
| legacy | factory 0xd159… | same setters | | keep deprecated |
| legacy | hook 0xa5ea… | `setProtocolFeeNumerator` (factory owner) up to 50% of lp fee, taken to the factory | raises LAYER trading cost | leave at 0, document as the one live fee lever |
| legacy | `ArtCoinsLpLockerMultiple`, `ArtCoinsFeeLocker` | withdrawETH/ERC20 stray, addDepositor | slot admins may still repoint LAYER recipients | check who holds LAYER slot admins |
| legacy | LAYER burn router, protocol fee controller, LL extensions and renderer | thresholds, floors, sweeps, split, treasury, renderer strings | yes, LAYER flows | inventory in runbook |

## 3. changes

each block names the regression test. tests are fork tests against live v4 using `test/v2/harness/ForkBase.sol` and `ForkStack.sol`; file `test/v2/<Area>V2.fork.t.sol`.

### b2. recipient with no code or empty fallback bricks swaps
v1 `try IPreSwapStream(br).streamForward() {} catch {}` decoded the uint256 return outside the try: an eoa or empty fallback returns no data, decode reverts the swap (whenever the recipient holds >= 0.01 eth). separately, a bounty push failure reverted the swap.
| item | design |
|---|---|
| contract | `ArtCoinsHookV2` |
| delivery | fee legs are pushed with a zero gas call (`_PUSH_GAS = 0`), so the recipient runs on the evm's 2,300 stipend only; a failed push is credited in the fee escrow. no `streamForward` probe (D41, D60) |
| storage | `HookGlobals { address feeEscrow; address extensionAllowlist; }` one struct, owner set |
| events | `FeeDelivered(poolId, leg, to, amount, escrowed)` per leg; no delivery tunable |
| invariant | no recipient behavior (no code, empty fallback, revert, gas burn, huge returndata) can revert a swap; the stipend lets the recipient read state and call `PoolManager.sync`, nothing else (D60) |
| tests | `test_swap_bountyEoaWithBalance_noRevert`, `test_swap_bountyEmptyFallback_noRevert`, `test_swap_bountyReturnBomb_bounded`, `test_swap_bountyGasBurner_bounded`, `test_swap_bountyRejectsEth_escrowed` |

### b3. skim charged on the unfilled part of a price limited swap
when the quote side is specified, `_beforeSwap` mints the skim S on the full abs(amountSpecified). a `sqrtPriceLimitX96` partial fill leaves the trader paying S on volume that never traded.
| item | design |
|---|---|
| contract | `ArtCoinsHookV2` |
| flow | `_beforeSwap` mints S claims and stores `tstore(SKIM_PENDING, S)`, `tstore(SKIM_REQUESTED, abs(amountToSwap))`. `_afterSwap` (quote specified branch) reads realized `R = abs(delta.quote)`; `fair = S * R / requested`; legs are split on `fair`; `over = S - fair` is burned, taken, and credited in the escrow to the hookData refund address (the swap reverts when a partial fill carries no refund address, D93) |
| storage | accruals move from mappings (`accruedBounty`, `accruedProtocol`, `accruedReferral`) to transient slots. public `accruedReferral` getter is removed (always zero in v1) |
| events | `SkimRefunded(PoolId indexed poolId, address indexed to, uint256 amount)` |
| invariant | trader quote cost = realized + fair; fair + over = S; hook erc6909 balance is zero after every `_afterSwap` |
| tests | `test_skim_exactInPriceLimited_refundsUnfilled`, `test_skim_exactOutPriceLimited_refundsUnfilled`, `test_skim_fullFill_noRefund`, `test_burnRouterV2_claimsRefund` |

### b4. launch hijack
| item | design |
|---|---|
| contracts | `ArtCoinsFactoryV2`, `ArtCoinsDeployerV2` |
| functions | `function configHash(DeploymentConfigV2 calldata c) public pure returns (bytes32)` = `keccak256(abi.encode(c))`. `function predictToken(address sender, DeploymentConfigV2 calldata c) external view returns (address)`. deployer `deploy(TokenConfigV2 memory t, uint256 supply, RestrictionConfigV2 memory restriction, ArtCoinsTokenV2.CanonicalPool memory canon, address launcher, bytes32 salt)` with `salt = keccak256(abi.encode(msg.sender, configHash(c)))` computed by the factory |
| also | `initializePoolOpen` removed (d3), so a predicted pool key cannot be pre initialized on the hook |
| invariant | token address is a function of (factory, sender, full config). a front runner with a different sender, or any different field, gets a different address and cannot block or capture the victim's launch |
| tests | `test_launch_frontrunCopiedConfig_differentAddress`, `test_launch_changedLockerConfig_differentAddress`, `test_launch_predictTokenMatches` |

### b5. escrow credit strandable by third party claim
`escrow.claim(feeOwner, token)` is permissionless, so a third party can push a contract recipient's credit to it at a time the recipient does not expect. The live 111 fee converter 0xeBD9… has this exposure and no sweep.
| item | design |
|---|---|
| contract | `ArtCoinsFeeEscrowV2` |
| escrow | `mapping(address => bool) public selfClaimOnly; function setSelfClaimOnly(bool on) external` (msg.sender is the feeOwner). `claim` reverts `Unauthorized()` when `selfClaimOnly[feeOwner] && msg.sender != feeOwner` |
| events | `SelfClaimOnlySet(address indexed feeOwner, bool on)` |
| invariant | a feeOwner that opted in receives its credit only through its own call |
| tests | `test_escrowV2_selfClaimOnly_blocksThirdParty`, `test_escrowV2_selfClaimOnly_ownerCanClaimItself` |

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
| users | hook (bounty, protocol, referral legs), ProtocolFeeControllerV2 |
| referral | the referrer named in hookData receives `referralBps` of volume (per pool rate set by the coin admin, default 0, at most 100 bps, D98), carved from the protocol leg and capped by it. pushed with the 2,300 gas stipend like the other legs, escrow on failure (D16, D59) |
| events | hook `FeeDelivered(PoolId indexed poolId, uint8 indexed leg, address indexed to, uint256 amount, bool escrowed)`; `SkimRefunded(PoolId indexed poolId, address indexed to, uint256 amount)` for the refund credit |
| invariant | delivery never reverts its caller once the caller is a core depositor; every wei reaches `to` or `to`'s escrow balance |
| tests | `test_delivery_payable_pushed`, `test_delivery_reverting_escrowed`, `test_delivery_gasBurner_escrowed` |

### d2. launch restriction: either-side allowlist with a transient PoolManager allowance
`restricted` is set on the token at construction (`RestrictionConfigV2.restricted`) and mirrored into the hook pool record at init. `unrestrict()` clears it permanently.

| item | design |
|---|---|
| rule | while restricted, a transfer or transferFrom reverts `TransferRestricted(from, to, amount)` unless `from` or `to` is on the allowlist, or one side is the PoolManager and the amount fits the transient allowance. Mint and burn skip the rule. While not restricted every transfer passes |
| allowlist | the launch locker, then the launch extensions, then `RestrictionConfigV2.allowed`, assembled by the factory (`_restriction`), at most `Constants.MAX_ALLOWED` entries. `allowed` is empty when `restricted` is false (`InvalidRestrictionConfig`). The PoolManager and the canonical hook are rejected (`AllowedForbidden`) |
| allowance | `_afterSwap` calls `token.increaseTransferAllowance(poolId, abs(coin delta))` for a restricted pool. The token adds it to a transient slot, `_route` consumes it on a PoolManager side transfer in the same tx. Only `canonicalHook` may call it, and a different pool id or a zero amount returns without effect |
| admin | `setAllowed`, `unrestrict` and `lock` (token admin). `lock()` freezes `setAllowed` and `unrestrict` |
| views | `isAllowed(account)`, `isTransferRestricted(from, to)`, `transferAllowance()` |
| known limits | the token checks the two transfer parties only, so a listed router, aggregator, multicall or smart wallet moves coin between any two wallets. erc6909 claims of the coin can circulate inside the PoolManager on side pools and cannot exit as erc20 without the allowance |
| tests | `test/v2/TokenV2.t.sol`, `test/v2/HookV2.fork.t.sol` |

v4 picks the `take` recipient after the hook returns, so the hook cannot name the taker. The allowance is bound to the canonical pool, to the tx (transient), and to the realized swap delta amount; see open decision 8.

### d3. no open pools, official pools distinguishable
| item | design |
|---|---|
| hook | `initializePoolOpen` removed. `_beforeInitialize` reverts unless the hook itself is initializing inside `initializePool` (transient flag). `struct PoolInfo { uint16 version; bool restricted; uint40 createdAt; address launcher; address token; address locker; address mevModule; address extension; }`, `function poolInfo(PoolId) external view returns (PoolInfo memory)`, `function isOfficialPool(PoolId) external view returns (bool)` (launcher != 0) |
| factory | `deploymentInfo(token)` returns `DeploymentInfoV2 { address token; address hook; address locker; address mevModule; address escrow; PoolId poolId; bytes32 configHash; uint16 version; uint40 launchedAt; bool restricted; address[] extensions; }` |
| tests | `test_hookV2_noOpenInit`, `test_hookV2_directPoolManagerInit_reverts`, `test_hookV2_poolInfo_matchesLaunch` |

### d4. sender in salt, full config in launch event
b4 covers the salt. section 6 covers the event.

### d5. one constants file, checked at init
`src/Constants.sol` (section 4). every v2 contract has `function constantsHash() external pure returns (bytes32) { return Constants.hash(); }`. checks: factory `setHook`, `setLocker`, `setMevModule`, `setExtension`, `setTokenDeployer`; hook `setFeeEscrow` checks the escrow and `initializePool` checks the locker and the mev module; module `initialize` checks the hook; locker `placeLiquidity` checks the hook. a mismatch reverts `ConstantsMismatch(address module)`. constructor asserts cost no runtime bytes, so the hook may also assert in its constructor that `Hooks.validateHookPermissions` matches section 5. test `test_constants_mismatchedModule_rejected`.

### d6. version tag per pool
`Constants.STACK_VERSION = 2`. token: `function launcherVersion() external pure returns (uint16)`, `address public immutable launcher`. hook: `poolInfo(pid).version`. factory: `STACK_VERSION`, `DeploymentInfoV2.version`, event field. integrators check `hook.poolInfo(pid).version == 2 && factory.isArtCoin(token)`. test `test_versionTag_consistentAcrossTokenHookFactory`.

### d7. deployment hygiene
| item | design |
|---|---|
| one factory | `script/v2/DeployV2Stack.s.sol` deploys constants checked stack in one broadcast: the 12 contract stack: escrow, extension allowlist, hook (mined salt, flags in section 5), locker, linear skim module, factory, token deployer, burn router, protocol fee controller and the three launch extensions (dev buy, airdrop, vault). wires core depositors, launchers, enables the hook, locker, mev module and extensions; the factory ships `deprecated` and opening it is a separate owner tx |
| verify | `script/v2/verify-v2.sh` runs `forge verify-contract` for every address with profile `ci`, then a chain check that the on chain runtime equals the local ci build |
| superseded | `deployments/mainnet.json` lists every stack with a status (`current`, `deployed`, `planned`, `superseded`, `legacy`); a replaced v2 stack stays listed as `v2-<deployedAt>` (D96). owner txs: 0xf051 `setDeprecated(true)`; 0x4959 `setHook(0x636c…, false)` after v2 is live |
| tests | `test_deployV2Stack_wiringComplete`, `test_deployV2Stack_runtimeMatchesBuild` |

protocol fees leave the stack through `ProtocolFeeControllerV2.processFees()` and `BurnRouterV2.processBurn(minOut)` (D92).

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

    // fee push gas cap (controller; the hook pushes with zero gas)
    uint32 internal constant PUSH_GAS_MAX = 150_000;

    // anti sniper window (module and hook agree)
    uint32 internal constant MIN_MEV_WINDOW = 1 minutes;
    uint32 internal constant DEFAULT_MEV_WINDOW = 69 minutes;
    uint32 internal constant MAX_MEV_WINDOW = 180 minutes;
    uint24 internal constant DEFAULT_START_SKIM_BPS = 68_690;

    // locker
    uint256 internal constant MAX_LP_POSITIONS = 14;

    // factory
    uint256 internal constant DEFAULT_TOKEN_SUPPLY = 1_000_000_000e18;
    uint256 internal constant MIN_TOKEN_SUPPLY = 1e18;
    uint256 internal constant MAX_EXTENSIONS = 10;
    uint16 internal constant MAX_EXTENSION_BPS = 9_000;
    uint256 internal constant MAX_DEPLOY_FEE = 1 ether;

    // token restriction
    uint256 internal constant MAX_ALLOWED = 64;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // burn router
    uint256 internal constant SPOT_FLOOR_BPS = 8_000;
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
        // grouped: pool fee config, the push gas cap, launch limits.
        return keccak256(
            abi.encode(
                STACK_VERSION, MAX_SKIM_BPS, MAX_BASELINE_SKIM_BPS,
                MAX_REFERRAL_CAP_OF_VOLUME, MAX_BOUNTY_BPS, MIN_MEV_WINDOW, MAX_MEV_WINDOW,
                MAX_LP_POSITIONS, MAX_ALLOWED, SPOT_FLOOR_BPS, PUSH_GAS_MAX
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
| beforeAddLiquidity (1<<11) | yes | yes | mev lock |
| afterAddLiquidity (1<<10) | no | no | |
| afterRemoveLiquidity (1<<8) | yes | no | |
| beforeSwap (1<<7) | yes | yes | skim on specified quote, stream probe |
| afterSwap (1<<6) | yes | yes | skim on unspecified quote, refund (b3), transfer allowance grant (d2), delivery |
| beforeSwapReturnDelta (1<<3) | yes | yes | |
| afterSwapReturnDelta (1<<2) | yes | yes | |
| low 14 bits | 0x29CC (matches live 0x…a9cc) | 0x28CC | mine with `HookMiner` against CREATE2 deployer 0x4e59…956C |

size plan. measured: v1 source `ArtCoinsHookSkimFee` is 20,558 bytes at the ci profile (runs 200), 4,018 bytes headroom; `SkimFeeInitLib` 943 bytes. the "29 bytes headroom" note in foundry.toml is stale and must be corrected by h1. so v2 fits even without the cold module, but the margin is thin once the additions land, and raising runs above 200 (cheaper swaps) needs room. v2 target: <= 20,000 bytes at runs 200; ci gate fails below 2,048 bytes headroom.

| lever | bytes (estimate, measured by package h1 before merge) |
|---|---|
| drop base hook surface the skim hook never needed: `initializePoolOpen`, `mevModuleSetFee`, `mevModuleSetSniperFee`, `mevModuleOperational`, sniper recipient set/lock/factorySet, 5 sniper getters, `weth` | minus 3,000 |
| freeze per pool fields: drop `setPoolExtension`, `lockPoolExtension`, `setMaxReferralBpsOfVolume`, `onlyTokenAdmin` (external `admin()` call inlined 6 times) | minus 1,300 |
| one attribution decoder instead of three external decode helpers; transient accruals instead of three mappings and a public getter | minus 600 |
| public constant getters replaced by one `constantsHash()` | minus 400 |
| drop the static fee variant: single concrete hook, no virtual `_setFee` / `_initializeFeeData` indirection | minus 200 |
| cold module: `fallback()` delegatecalls an immutable `HookColdModule` for `initializePool`, `initializeMevModule`, owner setters, rescue, `skimConfig`, `poolInfo`, ownership. hook keeps one dispatch stub. storage in an erc7201 namespaced struct shared by both (`HookStorage.layout()`) | minus 3,500 |
| additions: push with fallback, stream probe, partial fill refund, transfer allowance grant, launcher check | plus 2,700 |
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
    string description;
    uint256 totalSupply;   // 0 = default
    address renderer;
}
struct PoolConfigV2 {
    address hook;
    int24 tickIfToken0IsCoin;
    int24 tickSpacing;
    address extension;     // frozen per pool, 0 for none
    bytes extensionData;
}                          // paired currency is always native eth
struct FeeConfigV2 {
    uint24 baselineSkimBps;
    uint16 bountyBps;      // <= MAX_BOUNTY_BPS
    address payable bountyRecipient;
    uint24 referralBps;    // <= 100 bps of volume, 0 = off (D98); the coin admin changes it later
}                          // protocolRecipient is injected by the factory
struct LockerConfigV2 {
    address locker;
    int24[] tickLower;
    int24[] tickUpper;
    uint16[] positionBps;
}
struct MevConfigV2 {
    address module;        // must be an IArtCoinsMevSkim with matching constantsHash
    uint24 startingSkimBps;
    uint32 windowSeconds;  // <= MAX_MEV_WINDOW
}
struct RestrictionConfigV2 {
    bool restricted;       // transfer allowlist on or off
    address[] allowed;     // extra entries, empty when not restricted; the factory prepends the locker and extensions
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
    RestrictionConfigV2 restriction;
    ExtensionConfigV2[] extensions;
}

function deployToken(DeploymentConfigV2 calldata c) external payable returns (address token);

event TokenCreatedV2(
    address indexed sender,
    address indexed token,
    PoolId indexed poolId,
    uint16 stackVersion,
    bytes32 configHash,
    address protocolRecipient,
    uint256 poolSupply,
    uint256 extensionsSupply,
    DeploymentConfigV2 config
);
```

notes: the whole config is emitted, so an indexer can rebuild every frozen field from one log.

## 7. credits engine coin: interface changes

the treasury is the fee recipient. it may have a payable fallback and must work with eth.

| surface | v1 behavior | v2 behavior | treasury needs |
|---|---|---|---|
| `IPreSwapStream.streamForward()` probe | high level call, all gas, return decoded outside try: eoa or empty fallback with >= 0.01 eth bricks swaps | removed (D41, D60); the hook makes no call to the treasury other than the fee push | none |
| bounty leg | push all gas, revert swap on failure | push with zero gas (the 2,300 gas stipend), escrow on failure, `FeeDelivered` event | `receive` or payable fallback within the stipend. otherwise funds sit in escrow under the treasury |
| escrow fallback | n/a | `claim(treasury, address(0))` permissionless unless the treasury opts into `selfClaimOnly` | nothing if its fallback is payable; anyone can push the balance. a treasury that cannot receive plain eth must call `claimTo` itself |
| weth | lp side paid weth on weth pools | v2 pools are native eth only, nothing pays weth | wrap itself if it wants weth |
| protocol and referral legs | deployer chosen | the factory injects the protocol recipient; the referral is a per pool rate (`referralBps`, default 0, coin admin) paid to the referrer named in hookData | none |
| hookData | `PoolSwapData{mevModuleSwapData, poolExtensionSwapData = abi.encode(PCSwapData)}` | `SwapData{mevModuleSwapData = abi.encode(address refundTo), poolExtensionSwapData = abi.encode(address referrer, bytes payload)}`. A charged partial fill without a refund address reverts `RefundAddressRequired` (D93) | none |
| version and discovery | none | `hook.poolInfo(pid)`, `factory.deploymentInfo(token)`, `token.launcherVersion()` | none |
| accounting | `LegForwarded` | `FeeDelivered`, `SkimRefunded` | index these, no callback (open decision 15) |

## 8. work breakdown

v1 files are read only for every package. each package owns its files and its fork tests.

| pkg | owner files | depends on | deliverable |
|---|---|---|---|
| a0 constants and interfaces | `src/Constants.sol`, `src/v2/interfaces/*` (`IArtCoinsHookV2`, `IArtCoinsTokenV2`, `IArtCoinsFactoryV2` with section 6 structs, `IArtCoinsLpLockerV2`, `IArtCoinsFeeEscrowV2`, `IConstantsBound`), `test/v2/ConstantsV2.t.sol` | none | lands first, frozen after review |
| t1 token and deployer | `src/v2/ArtCoinsTokenV2.sol`, `src/v2/utils/ArtCoinsDeployerV2.sol`, `test/v2/TokenV2*.fork.t.sol` | a0 | d2 token, d6 |
| h1 hook | `src/v2/hooks/ArtCoinsHookV2.sol`, `HookColdModule.sol`, `HookStorage.sol`, `test/v2/HookV2*.fork.t.sol`, size gate in `foundry.toml` ci profile comment | a0, t1 interface | b2, b3, b7 hook half, d1 hook, d2 hook, d3, section 5 measured |
| l1 locker, escrow, delivery | `src/v2/lp-lockers/ArtCoinsLpLockerV2.sol`, `src/v2/ArtCoinsFeeEscrowV2.sol`, `src/v2/libraries/FeeDelivery.sol`, `test/v2/LockerV2*.fork.t.sol`, `test/v2/EscrowV2*.fork.t.sol` | a0 | b5 escrow half, d1 |
| m1 mev | `src/v2/mev-modules/ArtCoinsMevLinearSkimV2.sol`, tests | a0 | b7 module half |
| p1 periphery | `src/v2/protocol-fee/BurnRouterV2.sol`, `src/v2/protocol-fee/ProtocolFeeControllerV2.sol`, tests | a0, l1 (FeeDelivery) | b6 |
| r1 renderers | `src/v2/renderer/*`, tests | a0 | b8 |
| f1 factory | `src/v2/ArtCoinsFactoryV2.sol`, `test/v2/FactoryV2*.fork.t.sol` | a0, t1, h1, l1, m1 | b4, d3 factory half, d4, section 6 |
| s1 deploy | `script/v2/DeployV2Stack.s.sol`, `script/v2/verify-v2.sh`, `test/v2/DeployV2Stack.fork.t.sol`, `test/v2/harness/ForkStack.sol` additions | all contracts | d7 |
| i1 integration | `test/v2/IntegrationV2.fork.t.sol` (credits engine style treasury mocks: no code, empty fallback, reverting, gas burner, IPreSwapStream good and bad) | s1 | end to end launch, swaps, fee delivery, restricted and unrestricted coins |
| u1 ui and scripts | `ui/src/lib/encode.ts`, `ui/src/lib/abi.ts`, `ui/src/lib/config.ts`, `script-js/*` | a0, s1 | v2 config encoding (ui still encodes the static fee pool data today) |

integration order: a0, then t1 h1 l1 m1 p1 r1 in parallel, then f1, then s1, then i1, then u1. h1 owns the size number; f1 may not merge until h1's ci size gate passes.

## 9. open decisions (recommendation first)

| # | decision | recommendation | alternative |
|---|---|---|---|
| 2 | pool extension after launch | frozen at launch | token admin swap and lock (v1) |
| 3 | referral cap after launch | frozen | token admin within 1% (v1) |
| 7 | partial fill over skim | escrow credit to the hookData refund address; a partial fill with no refund address reverts `RefundAddressRequired` (D93) | credit the router that called the PoolManager (a router cannot claim); revert every partial fill (breaks price limited burners) |
| 8 | taker binding | canonical pool, tx, realized swap delta amount (true taker binding is impossible in v4) | require a recipient in hookData (breaks aggregators) |
| 9 | escrow third party claim | permissionless with `selfClaimOnly` opt in | self claim only for contracts (strands treasuries that cannot call out) |
| 10 | hook size strategy | immutable cold module via fallback | per function delegate stubs, or runs 100 |
| 11 | baseline skim cap | 10% of volume (111 uses 6%) | keep 90% |
| 12 | referral leg failure | credit the referrer in escrow | fold into protocol (v1) |
| 13 | weth paired pools | native eth only | allow weth |
| 14 | stream probe gas default | 150k, owner bounds 30k..500k; measure 0x8C72 `streamForward` gas on a fork before freezing | uncapped (v1) |
| 15 | fee receiver callback | none, events only | erc165 opt in callback |
| 16 | owner key handling | Ownable2Step on every owned v2 contract | plain Ownable |
| 17 | LAYER legacy `protocolFeeNumerator` | leave 0, document | none (cannot be removed) |
| 19 | escrow depositor removal | core depositors (hook) cannot be removed | free removal (can brick fallback) |
| 20 | v1 lp fee mev modules | not shipped in v2 | port them with a hook fee path (costs size) |
| 21 | push gas default | 50k (v1 forward gas was 35k) | 35k |
