# credits engine treasury: v2 interface

for the credits engine developer. the first coin on the v2 stack has the treasury contract as fee recipient (bounty recipient). the treasury receives eth fees, may or may not implement the v1 `IPreSwapStream.streamForward()`, and may have a payable fallback that does accounting (more than 2,300 gas). sources: `docs/v2/DECISIONS.md` (D13, D16, D17, D19, D28, D33, D36, D41, D52, D57, D58, D60, D73, D74, D76), `src/v2/interfaces/`, `src/v2/hooks/ArtCoinsHookV2.sol`, `src/v2/ArtCoinsFactoryV2.sol`, `src/v2/ArtCoinsFeeEscrowV2.sol`.

## 1. v1 (111 stack) vs v2

| surface | v1 (111 stack) | v2 | treasury action |
|---|---|---|---|
| stream probe | hook called `streamForward()` before every swap with all gas, return decoded outside try | removed. the hook never calls a recipient with a probe; fee legs are pushed with a zero gas call, so a recipient runs only on the evm's 2,300 gas stipend (it can read state and call `PoolManager.sync`, nothing else; the hook resets sync after the pushes; revert, gas burn and returndata are contained by the escrow fallback; an erc20 prepay style router that syncs before the swap must be tested before being declared supported, D60) | none. if the treasury relied on the pre swap call, see section 3 |
| bounty leg | push with all gas, swap reverts on failure | push with the 2,300 gas stipend only (`call` with gas 0 and value), on failure `ArtCoinsFeeEscrowV2.storeFeesNative` credits the recipient (claim with `escrow.claim`), `FeeDelivered(poolId, leg, to, amount, escrowed)` | accept eth in 2,300 gas, or pull from escrow |
| eth receive, option a | n/a | a `receive()` that does nothing but accept. no sstore, no cold sload (2,100), no external call, no delegatecall. a proxy treasury fails this (the implementation slot read is cold) | empty `receive() external payable {}` on the treasury itself |
| eth receive, option b | n/a | do nothing. every bounty push fails, funds sit in escrow under the treasury address, anyone can call `escrow.claim(treasury, address(0))` | payable fallback may do accounting here: the claim forwards all gas |
| eth receive, option c | n/a | any wallet (or the treasury itself) calls `claim` on a schedule | `setSelfClaimOnly(true)` on the escrow from the treasury if only the treasury may trigger the push |
| paired currency | weth pools possible | native eth only (D17) | wrap itself if it wants weth |
| protocol and referral | deployer chosen | factory injected: `protocolRecipient` (the stack fee controller `ProtocolFeeControllerV2`, which a bot drains with `processFees()`). the referral is paid to the referrer directly, stipend push, escrow on failure (D16). there is no stored referral payout pointer (D76) | none |
| referral (D98) | per coin referral cap, protocol floor | per pool rate `SkimConfig.referralBps` set by the coin admin (`hook.setReferralBps`, default 0 = off, cap 100 bps = 1% of volume, frozen by `lock()`), paid to the referrer a swap names out of the protocol leg and never above that leg | none |
| recipient changes | slot admin removed in v1 | the coin admin may repoint the bounty recipient (`hook.setBountyRecipient(poolId, recipient)`) after launch. the setter applies its own recipient checks (section 4). `token.lock()` freezes the setter, and `bountyBps` is fixed at launch | move the treasury without a custom router; call `lock()` when final |
| restriction (D73, D74) | n/a | one launch flag `restricted`. while set, holder to holder transfers revert unless a side is on the coin allowlist; coin moves to or from the PoolManager only within the transient allowance the canonical hook grants for a canonical swap in the same transaction, which the transfer consumes. restriction is fee priced, not absolute (D74): a canonical round trip of X in one transaction grants 2X allowance and consumes none, so a holder can move X through PoolManager balances at the cost of the home pool round trip fees. the cost of moving a restricted coin wallet to wallet through a canonical round trip equals the launcher's chosen home pool fees, so a restricted coin with near zero fees restricts transfers only nominally (launcher's choice, no fee floor for restricted coins, D80). the credits coin launches NOT restricted (plain erc20) | leave `restriction.restricted = false` for a plain erc20 |
| restriction allowlist | n/a | the coin admin manages the allowlist (`setAllowed`) and may turn restriction off once (`unrestrict`). the factory seeds the allowlist with this launch's locker, the launch extensions and the launch config's `restriction.allowed` list; the coin admin can edit every entry until `lock()`. `token.lock()` (admin only, once, error `CoinLocked`) freezes `setAllowed`, `unrestrict`, `hook.setBountyRecipient`, `hook.lowerBaselineSkim` and `hook.setPoolExtension`. image, description, renderer and admin transfer stay editable. the PoolManager and the canonical hook are rejected entries (`AllowedForbidden`). a router, aggregator or forwarder must not be listed | allowlist only contracts whose coin outflows are fixed by their own logic |
| skim refund (D42, D51, D58) | n/a | the over charge on a price limited partial fill is credited in the fee escrow to the refund address the swapper names in hookData (`mevModuleSwapData = abi.encode(address)`), a partial quote specified fill without a valid refund address reverts `RefundAddressRequired`. v4 lets `afterSwap` return a delta only on the unspecified currency, which for a quote specified fill is the coin, so an eth refund rides the escrow, not the return delta. `SkimRefunded(poolId, to, amount)` marks it | pass a refund address in hookData |
| callbacks (D19) | `streamForward` | none, events only | index events, section 5 |
| discovery | none | `hook.poolInfo(pid).version == 2`, `factory.isCoin(token)`, `token.launcherVersion()`, `factory.deploymentInfo(token)` | use for allowlisting and sanity checks |

fee legs per swap: bounty, protocol, referral (`Constants.LEG_BOUNTY` 0, `LEG_PROTOCOL` 1, `LEG_REFERRAL` 2). all three are eth.

## 2. receiving eth, decision table

| treasury shape | what happens on a bounty push | what to do |
|---|---|---|
| eoa style, or `receive() {}` and nothing else, not behind a proxy | push lands, `escrowed = false` | nothing |
| payable fallback that does accounting (more than 2,300 gas), or a proxy | push fails, credited to the treasury in the escrow, `escrowed = true`. the swap is not affected | pull with `escrow.claim(treasury, address(0))`. claim forwards all gas, so the accounting runs there. if the fallback reverts the claim reverts and the balance stays safe |
| no payable receive at all | push fails, escrowed | the treasury calls `escrow.claimTo(treasury, address(0), payable(target))` itself (fee owner only). plain `claim` reverts `NativeTransferFailed` |
| wants only itself to trigger the push | n/a | call `escrow.setSelfClaimOnly(true)` from the treasury. then `claim(treasury, 0)` from anyone else reverts `Unauthorized`. cost: nobody else can flush it, so the treasury or its bot must call it |
| default (selfClaimOnly false) | n/a | anyone can trigger the payout at any time. the treasury fallback must tolerate being called at arbitrary moments, with the full gas of the claimer |

the escrow is `IArtCoinsFeeEscrowV2`: `balances(feeOwner, token)`, `claim`, `claimTo`, `setSelfClaimOnly`, `selfClaimOnly`. token `address(0)` is native eth. the hook is a core depositor; the current escrow is the one wired into the hook (`hook.globals().feeEscrow`); the owner can rotate it, so read the current pointer there. `factory.deploymentInfo(token).escrow` records the escrow at launch time and does not follow a rotation; credits already booked stay claimable in the escrow that booked them.

## 3. if the treasury keeps the v1 streamForward design

| item | v2 reality |
|---|---|
| is `streamForward()` called by the hook | never. not before swaps, not after |
| does an implementation break anything | no. an unused function is harmless, nothing probes for it |
| how to drive the forwarding | (1) a bot (any wallet, cron) calls the treasury's own forward function after fees land; (2) the treasury's own claim: call `escrow.claim(treasury, 0)` then run the forward logic in the same tx; (3) put the forward logic in the payable fallback so any claim triggers it, with the accounting gas caveat in section 2 |
| what to drop | any reliance on being called before the swap, any assumption that fees are in the treasury balance at swap time (they may be in escrow) |
| what to add | a function that sums `address(this).balance` plus `escrow.balances(address(this), 0)` and claims first |
| cadence | stipend pushes land per swap, so balance moves with volume. a bot tick hourly is enough; skip when pending is below gas cost |

## 4. launch call and config

| item | value |
|---|---|
| call | `factory.deployToken(DeploymentConfigV2 c)`, payable. the factory ships `deprecated()`; while deprecated only the owner can call it |
| value | `msg.value = deployFee + sum(extension msgValue)`. excess is refunded |
| set by the treasury integration | `fee.bountyRecipient = treasury` |
| injected by the factory | `protocolRecipient`. do not set it |
| `fee.bountyBps` | at most `MAX_BOUNTY_BPS` 9,999, else `BountyBpsTooHigh`. the referral is carved from the protocol leg that remains, so a bounty near the cap leaves referrers little |
| `fee.referralBps` | referral rate in bps of volume, 0 = off. at most `MAX_REFERRAL_CAP_OF_VOLUME` 100, else `FeeConfigOutOfBounds`. the coin admin changes it with `hook.setReferralBps(poolId, bps)` until `lock()` |
| `fee.bountyRecipient` | nonzero (`ZeroAddress`). launch reverts `RecipientCannotReceive` for the factory, the coin, the PoolManager, this launch's hook, locker, mev module and pool extension, the locker's PositionManager, the token deployer, the hook's current fee escrow and every former one (`hook.everFeeEscrow`), every launch extension in the config, every extension the factory has ever enabled, and the protocol recipient. a recipient that cannot take the 2,300 gas push is credited in the escrow and claimed with `escrow.claim`. `hook.setBountyRecipient` (coin admin only, until `lock()`) runs its own checks: nonzero (`BountyRecipientZero`), then `RecipientCannotReceive` for the coin, the hook, the PoolManager, the factory, the token deployer, the pool's mev module, locker and pool extension, the locker's PositionManager, every fee escrow the hook has had and every extension ever enabled; a lookup that reverts gives `RecipientCheckFailed`. the setter has no comparison against the protocol recipient. `hook.setPoolExtension` rejects an extension equal to the pool's current bounty recipient |
| restriction | `restriction.restricted` false for a plain erc20 (the credits coin). when true, the coin admin manages the allowlist; see the allowlist rule in `script/v2/README.md` |
| addresses | hook, locker, mev module, escrow come from the v2 registry (`deployments/mainnet.json`, generated `script/Addresses.sol`) once the v2 stack is deployed. none is hardcoded here |

example, matching `script/v2/launch-configs/example.json` (that file is the source of the numbers; replace `TREASURY`, `HOOK`, `LOCKER`, `MEV`, `ADMIN`):

```solidity
IArtCoinsFactoryV2.DeploymentConfigV2 memory c;
c.token = IArtCoinsFactoryV2.TokenConfigV2({
    tokenAdmin: ADMIN, name: "credits engine", symbol: "CREDITS",
    salt: bytes32(uint256(1)), image: "ipfs://...", description: "{}",
    totalSupply: 0, renderer: address(0)
});
c.pool = IArtCoinsFactoryV2.PoolConfigV2({
    hook: HOOK, tickIfToken0IsCoin: -200000, tickSpacing: 200,
    extension: address(0), extensionData: ""
});
c.fee = IArtCoinsFactoryV2.FeeConfigV2({
    baselineSkimBps: 600, bountyBps: 8333,
    bountyRecipient: payable(TREASURY)
});
int24[] memory lo = new int24[](3); lo[0] = -200000; lo[1] = -160000; lo[2] = -120000;
int24[] memory hi = new int24[](3); hi[0] = -120000; hi[1] = -100000; hi[2] = -60000;
uint16[] memory pos = new uint16[](3); pos[0] = 5000; pos[1] = 3000; pos[2] = 2000;
c.locker = IArtCoinsFactoryV2.LockerConfigV2({
    locker: LOCKER,
    tickLower: lo, tickUpper: hi, positionBps: pos
});
c.mev = IArtCoinsFactoryV2.MevConfigV2({
    module: MEV, startingSkimBps: 6869, windowSeconds: 4140
});
c.restriction = IArtCoinsFactoryV2.RestrictionConfigV2({
    restricted: false, allowed: new address[](0)
});
// c.extensions stays empty
address token = factory.deployToken{value: factory.deployFee()}(c);
```

checks on those numbers: position bps 5,000 + 3,000 + 2,000 is 10,000. the pool lp fee is 0 and the skim is the pool's only fee. skim 600 bps is the 6% baseline. window 4,140 s is 69 minutes. during that window the skim above the 6% baseline is paid entirely to the bounty recipient; the baseline portion splits bounty / protocol / referral.

## 5. events to index and bot cadence

| event | emitter | use |
|---|---|---|
| `TokenCreatedV2(sender, token, poolId, stackVersion, configHash, protocolRecipient, poolSupply, extensionsSupply, config)` | factory | rebuild every frozen field. confirm bounty recipient |
| `FeeDelivered(poolId, leg, to, amount, escrowed)` | hook | per swap leg. `leg` 0 is the bounty. `escrowed = true` means the balance is in escrow, claim it. no eth moved to the treasury in that case |
| `BountyRecipientSet(poolId, oldRecipient, newRecipient)` | hook | the coin admin repointed the bounty recipient (D76) |
| `Locked()` | token | the coin admin froze the admin setters (`lock()`) |
| `SkimRefunded(poolId, to, amount)` | hook | refund of the over charge on a price limited fill, credited in the escrow to the hookData refund address |
| `FeesStored`, `FeesClaimed` | escrow | reconcile the escrow balance of the treasury |
| `SkimSplit`, `SwapAttribution` | hook | volume and referral accounting, optional. a swap names its referrer as `abi.encode(address referrer, bytes extensionPayload)` in `poolExtensionSwapData` |
| `PoolInitializedV2(poolId, token, launcher, version, restricted, locker, mevModule, extension, tickSpacing)` | hook | discovery |

the credits engine receives its fees through the bounty leg only. protocol fees leave the stack through `ProtocolFeeControllerV2.processFees()` and `BurnRouterV2.processBurn(minOut)`, called by the LAYER bot.

| cadence | rule |
|---|---|
| bounty leg | per swap. only the escrow fallback needs a claim, poll `escrow.balances(treasury, 0)` |

## 6. checklist: what the treasury contract must satisfy

| requirement | needed | yes or no |
|---|---|---|
| receives eth by plain transfer within 2,300 gas | no, only for direct bounty pushes. otherwise it pulls from escrow | yes or no |
| no storage write, no cold read, no proxy in `receive()` if it wants direct pushes | yes for direct pushes | yes or no |
| can call `escrow.claim(treasury, 0)` or is callable by a bot that does | yes if the fallback is heavy | yes or no |
| payable fallback tolerates being triggered by anyone at any time with the claimer gas | yes if selfClaimOnly stays false | yes or no |
| payable fallback does not revert on zero or tiny value | yes, a revert makes claim revert | yes or no |
| calls `setSelfClaimOnly(true)` if only it may trigger the push | optional | yes or no |
| can send `claimTo` to a payable target if it has no payable receive | yes if no payable receive | yes or no |
| does not depend on `streamForward()` being called | yes | yes or no |
| never calls the PoolManager from inside a fee receive path | yes | yes or no |
| is not the hook, the PoolManager or address zero | yes | yes or no |
| indexes `FeeDelivered`, `TokenCreatedV2`, `SkimRefunded`, and `BountyRecipientSet` | yes | yes or no |
| eth only: wraps itself if it wants weth | yes | yes or no |
| config: `bountyBps` and `baselineSkimBps` pass section 4 limits | yes | yes or no |

note: the hook legs use the stipend (a zero gas call); the escrow `claim` forwards all gas.

## fee recipient rule

every fee recipient (bounty, protocol) must accept native eth or be able to call `escrow.claimTo(self, token, to)`. failed pushes are credited in the escrow under the recipient's address; a recipient that can neither receive eth nor call `claimTo` leaves those credits stranded. the stack rejects its own known contracts as recipients; choosing any other unpayable contract is the chooser's loss (D81).
