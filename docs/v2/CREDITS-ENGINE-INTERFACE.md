# credits engine treasury: v2 interface

for the credits engine developer. the first coin on the v2 stack has the treasury contract as fee recipient (bounty recipient) and as a project reward slot. the treasury receives eth fees, may or may not implement the v1 `IPreSwapStream.streamForward()`, and may have a payable fallback that does accounting (more than 2,300 gas). sources: `docs/v2/DECISIONS.md` (D13, D16, D17, D19, D28, D33, D36, D41, D52, D57, D58, D60, D73, D74, D76), `src/v2/interfaces/`, `src/v2/hooks/ArtCoinsHookV2.sol`, `src/v2/lp-lockers/ArtCoinsLpLockerV2.sol`, `src/v2/ArtCoinsFactoryV2.sol`, `src/v2/keepers/ArtCoinsKeeperV2.sol`.

## 1. v1 (111 stack) vs v2

| surface | v1 (111 stack) | v2 | treasury action |
|---|---|---|---|
| stream probe | hook called `streamForward()` before every swap with all gas, return decoded outside try | removed. the hook never calls a recipient with a probe; fee legs are pushed with a zero gas call, so a recipient runs only on the evm's 2,300 gas stipend (it can read state and call `PoolManager.sync`, nothing else; the hook resets sync after the pushes; revert, gas burn and returndata are contained by the escrow fallback; an erc20 prepay style router that syncs before the swap must be tested before being declared supported, D60) | none. if the treasury relied on the pre swap call, see section 3 |
| bounty leg | push with all gas, swap reverts on failure | push with the 2,300 gas stipend only (`call` with gas 0 and value), escrow credit to the recipient on failure, `FeeDelivered(poolId, leg, to, amount, escrowed)` | accept eth in 2,300 gas, or pull from escrow |
| eth receive, option a | n/a | a `receive()` that does nothing but accept. no sstore, no cold sload (2,100), no external call, no delegatecall. a proxy treasury fails this (the implementation slot read is cold) | empty `receive() external payable {}` on the treasury itself |
| eth receive, option b | n/a | do nothing. every bounty push fails, funds sit in escrow under the treasury address, anyone can call `escrow.claim(treasury, address(0))` | payable fallback may do accounting here: the claim forwards all gas |
| eth receive, option c | n/a | a keeper (or the treasury itself) calls `claim` on a schedule | `setSelfClaimOnly(true)` on the escrow from the treasury if only the treasury may trigger the push |
| locker rewards | escrow deposit, pull | locker `collectRewards(token)` pushes both currencies per slot, escrow on failure, `RewardDelivered(token, currency, to, amount, escrowed)`. the locker is not inside a swap, so its eth push carries 150k gas (`PUSH_GAS_MAX`), not the stipend | eth: receive within 150k or pull from escrow. coin: arrives as erc20 `transfer`, no callback |
| eth only from the locker | slot recipient got both currencies | put a `FeeAutoSwapperV2` (`endRecipient = treasury`) in the slot. `convert` sells the coin side through the pool, `flushPaired` forwards eth. it pushes to the treasury with 500k gas and escrows on failure | register the swapper as an escrow depositor (D33, D36), deployer calls `setup(coin)` after launch |
| paired currency | weth pools possible | native eth only (D17), `quoteToken` must be 0 | wrap itself if it wants weth |
| protocol and referral | deployer chosen | factory injected: `protocolRecipient` (the stack fee controller), `referralPayout` (the escrow, D57). referral pays the referrer directly, stipend push, escrow on failure (D16) | none |
| protocol floor (D52) | referral could take the whole protocol leg | referral never takes the protocol leg below `minProtocolShareBps` of the baseline skim. `bountyBps <= 10000 minus minProtocolSkimShareBps` | config constraint, section 4 |
| lp fee (D76) | none removed | `fee.lpFee` ranges 0 to `MAX_LP_FEE` (100,000 pips). 0 is a pure skim pool with no lp fee; the D52 protocol skim floor still secures the protocol leg | config choice, section 4 |
| recipient changes (D76) | slot admin removed in v1 | the coin admin may repoint the bounty recipient (`hook.setBountyRecipient(poolId, recipient)`) and a project reward slot (`locker.setRewardRecipient(token, index, recipient)`) after launch. new recipients pass the launch receiver checks, bps stay fixed, the protocol reward slot stays frozen. `token.lockRecipients()` freezes both setters one way, and renouncing the coin admin freezes them | move the treasury without a custom router; freeze with `lockRecipients` when final |
| restriction (D73, D74) | n/a | one launch flag `restricted`. while set, holder to holder transfers revert unless a side is on the coin allowlist; coin moves to or from the PoolManager only within the transient allowance the canonical hook grants for a canonical swap in the same transaction, which the transfer consumes. restriction is fee priced, not absolute (D74): a canonical round trip of X in one transaction grants 2X allowance and consumes none, so a holder can move X through PoolManager balances at the cost of the home pool round trip fees. the credits coin launches NOT restricted (plain erc20) | leave `restriction.restricted = false` for a plain erc20 |
| restriction allowlist (D73, D76) | n/a | the coin admin manages the allowlist (`setAllowed`), may turn restriction off once (`unrestrict`), and may `lock` the allowlist and the switch. the factory seeds the allowlist with the owner `defaultAllowed` set (empty by default), this launch's locker, the stack fee escrow and the launch extensions, and pins those so the coin admin cannot remove them. the PoolManager, the canonical hook, and any router/aggregator/forwarder are prohibited entries | allowlist only contracts whose coin outflows are fixed by their own logic |
| skim refund (D42, D51, D58) | n/a | the over charge on a price limited partial fill is credited in the fee escrow to the refund address the swapper names in hookData (`mevModuleSwapData = abi.encode(address)`), else the PoolManager caller. v4 lets `afterSwap` return a delta only on the unspecified currency, which for a quote specified fill is the coin, so an eth refund rides the escrow, not the return delta. `SkimRefunded(poolId, to, amount)` marks it | pass a refund address in hookData, or claim it from the escrow |
| callbacks (D19) | `streamForward` | none, events only | index events, section 5 |
| discovery | none | `hook.poolInfo(pid).version == 2`, `factory.isArtCoin(token)`, `token.launcherVersion()`, `factory.deploymentInfo(token)` | use for allowlisting and sanity checks |

fee legs per swap: bounty, protocol, referral (`Constants.LEG_BOUNTY` 0, `LEG_PROTOCOL` 1, `LEG_REFERRAL` 2). all three are eth.

## 2. receiving eth, decision table

| treasury shape | what happens on a bounty push | what to do |
|---|---|---|
| eoa style, or `receive() {}` and nothing else, not behind a proxy | push lands, `escrowed = false` | nothing |
| payable fallback that does accounting (more than 2,300 gas), or a proxy | push fails, credited to the treasury in the escrow, `escrowed = true`. the swap is not affected | pull with `escrow.claim(treasury, address(0))`. claim forwards all gas, so the accounting runs there. if the fallback reverts the claim reverts and the balance stays safe |
| no payable receive at all | push fails, escrowed | the treasury calls `escrow.claimTo(treasury, address(0), payable(target))` itself (fee owner only). plain `claim` reverts `NativeTransferFailed` |
| wants only itself to trigger the push | n/a | call `escrow.setSelfClaimOnly(true)` from the treasury. then `claim(treasury, 0)` from anyone else reverts `Unauthorized`. cost: nobody else can flush it, so the treasury or its keeper must call it |
| default (selfClaimOnly false) | n/a | anyone can trigger the payout at any time. the treasury fallback must tolerate being called at arbitrary moments, with the full gas of the claimer |

the escrow is `IArtCoinsFeeEscrowV2`: `balances(feeOwner, token)`, `claim`, `claimTo`, `setSelfClaimOnly`, `selfClaimOnly`. token `address(0)` is native eth. the hook and locker are core depositors; the escrow address is the one the factory enabled (`factory.enabledEscrows`).

## 3. if the treasury keeps the v1 streamForward design

| item | v2 reality |
|---|---|
| is `streamForward()` called by the hook | never. not before swaps, not after |
| is it called by the keeper | no. `ArtCoinsKeeperV2` calls `collectRewards`, `flushPaired`, `convert` only |
| does an implementation break anything | no. an unused function is harmless, nothing probes for it |
| how to drive the forwarding | (1) a keeper (any wallet, cron) calls the treasury's own forward function after fees land; (2) the treasury's own claim: call `escrow.claim(treasury, 0)` then run the forward logic in the same tx; (3) put the forward logic in the payable fallback so any claim triggers it, with the accounting gas caveat in section 2 |
| what to drop | any reliance on being called before the swap, any assumption that fees are in the treasury balance at swap time (they may be in escrow) |
| what to add | a function that sums `address(this).balance` plus `escrow.balances(address(this), 0)` and claims first |
| cadence | stipend pushes land per swap, so balance moves with volume. a keeper tick hourly is enough; skip when pending is below gas cost |

## 4. launch call and config

| item | value |
|---|---|
| call | `factory.deployTokenAsOwner(DeploymentConfigV2 c, uint16 protocolBps)`, payable. `deployToken` works only if the factory is not `deprecated()`; the factory ships deprecated and owner only |
| value | `msg.value = deployFee + sum(extension msgValue)`. excess is refunded |
| protocol slot | `protocolBps` is the factory appended locker slot (example uses 2,000). project slots in `locker.rewardBps` must sum with it to 10,000 or `ProjectSideBpsMismatch` |
| set by the treasury integration | `fee.bountyRecipient = treasury`, `locker.rewardRecipients` (treasury or a fee swapper with `endRecipient = treasury`) |
| injected by the factory | `protocolRecipient`, `referralPayout`, the protocol locker slot. do not set them |
| `fee.bountyBps` | at most `10000 minus factory.minProtocolSkimShareBps()` (deploy script sets 1,000, so 9,000), also under `MAX_BOUNTY_BPS` 9,999. else `BountyBpsTooHigh` |
| referral cap | `maxReferralBpsOfVolume * 10000 <= baselineSkimBps * (10000 minus bountyBps minus minProtocolSkimShareBps)`, else `ReferralCapAboveProtocolFloor`. unit: volume in 1e5, 1,000 is 1% |
| `fee.lpFee` | 0 to `MAX_LP_FEE` 100,000 pips. 0 is a pure skim pool; the D52 protocol skim floor still pays the protocol leg |
| `fee.bountyRecipient` | not zero, not the hook, not the PoolManager (`RecipientCannotReceive`). the coin admin may change it after launch (`hook.setBountyRecipient`) until `lockRecipients` or admin renounce |
| restriction | `restriction.restricted` false for a plain erc20 (the credits coin). when true, the coin admin manages the allowlist; see the allowlist rule in `script/v2/README.md` |
| fee swapper | deploy it, `escrow.addDepositor(swapper, false)` by the escrow owner, list it in `locker.rewardRecipients`, deployer calls `swapper.setup(coin)` after launch |
| addresses | hook, locker, mev module, escrow come from the v2 registry (`deployments/mainnet.json`, generated `script/Addresses.sol`) once the v2 stack is deployed. none is hardcoded here |

example, matching `script/v2/launch-configs/example.json` (that file is the source of the numbers; replace `TREASURY`, `HOOK`, `LOCKER`, `MEV`, `ADMIN`):

```solidity
IArtCoinsFactoryV2.DeploymentConfigV2 memory c;
c.token = IArtCoinsFactoryV2.TokenConfigV2({
    tokenAdmin: ADMIN, name: "credits engine", symbol: "CREDITS",
    salt: bytes32(uint256(1)), image: "ipfs://...", metadata: "{}", context: "{}",
    totalSupply: 0, renderer: address(0)
});
c.pool = IArtCoinsFactoryV2.PoolConfigV2({
    hook: HOOK, tickIfToken0IsArtCoin: -200000, tickSpacing: 200,
    extension: address(0), extensionData: ""
});
c.fee = IArtCoinsFactoryV2.FeeConfigV2({
    lpFee: 5000, baselineSkimBps: 6000, bountyBps: 8333,
    maxReferralBpsOfVolume: 250, bountyRecipient: payable(TREASURY)
});
address[] memory rr = new address[](1); rr[0] = TREASURY; // or the fee swapper
uint16[] memory bps = new uint16[](1); bps[0] = 8000;
int24[] memory lo = new int24[](3); lo[0] = -200000; lo[1] = -160000; lo[2] = -120000;
int24[] memory hi = new int24[](3); hi[0] = -120000; hi[1] = -100000; hi[2] = -60000;
uint16[] memory pos = new uint16[](3); pos[0] = 5000; pos[1] = 3000; pos[2] = 2000;
c.locker = IArtCoinsFactoryV2.LockerConfigV2({
    locker: LOCKER, rewardRecipients: rr, rewardBps: bps,
    tickLower: lo, tickUpper: hi, positionBps: pos
});
c.mev = IArtCoinsFactoryV2.MevConfigV2({
    module: MEV, startingSkimBps: 68690, windowSeconds: 4140
});
c.restriction = IArtCoinsFactoryV2.RestrictionConfigV2({
    restricted: false, allowed: new address[](0)
});
// c.extensions stays empty
address token = factory.deployTokenAsOwner{value: factory.deployFee()}(c, 2000);
```

checks on those numbers: protocol 2,000 plus project 8,000 is 10,000. referral cap 250 times 10,000 is 2.5m, under 6,000 times (10,000 minus 8,333 minus 1,000) which is 4.0m. lpFee 5,000 pips is 0.5% (0 is also allowed). skim 6,000 in 1e5 units is the 6% baseline. window 4,140 s is 69 minutes. during that window the skim above the 6% baseline is paid entirely to the bounty recipient; the baseline portion splits bounty / protocol / referral.

## 5. events to index and keeper

| event | emitter | use |
|---|---|---|
| `TokenCreatedV2(sender, token, poolId, stackVersion, configHash, protocolRecipient, referralPayout, protocolBps, poolSupply, extensionsSupply, config)` | factory | rebuild every frozen field. confirm bounty recipient |
| `FeeDelivered(poolId, leg, to, amount, escrowed)` | hook | per swap leg. `leg` 0 is the bounty. `escrowed = true` means the balance is in escrow, claim it. no eth moved to the treasury in that case |
| `BountyRecipientSet(poolId, oldRecipient, newRecipient)` | hook | the coin admin repointed the bounty recipient (D76) |
| `RewardDelivered(token, currency, to, amount, escrowed)` | locker | per slot per collect. `currency` 0 is eth, else the coin |
| `RewardRecipientSet(token, index, oldRecipient, newRecipient)` | locker | the coin admin repointed a project reward slot (D76) |
| `RecipientsLocked()` | token | the coin admin froze both recipient setters (D76) |
| `SkimRefunded(poolId, to, amount)` | hook | refund of the over charge on a price limited fill, credited in the escrow to the hookData refund address or the PoolManager caller |
| `FeesStored`, `FeesClaimed` | escrow | reconcile the escrow balance of the treasury |
| `SkimSplit`, `SwapAttribution` | hook | volume and referral accounting, optional |
| `PoolInitializedV2(poolId, token, launcher, version, restricted)` | hook | discovery |

keeper: `ArtCoinsKeeperV2(factory)`, stateless, holds nothing. `collectAndForward(token, doConvert, minOut)` calls `locker.collectRewards(token)` (reverts bubble), then for each reward recipient that answers erc165 for `IFeeAutoSwapperV2` calls `flushPaired()` and, if `doConvert`, `convert(minOut)`, then forwards all eth and coin it holds to the caller. a recipient that is not a swapper (a plain treasury) is skipped, its share is pushed by the locker itself. pass a real `minOut` from a quote; `0` invites a sandwich bounded only by the swapper floor. gas floors: collect 900k, flush 150k, convert 400k. `preview(token)` reads swapper balances. locker keeper reward is 0 bps at launch, so the caller earns nothing unless the owner raises it (max 2%).

| cadence | rule |
|---|---|
| bounty leg | per swap, no keeper. only the escrow fallback needs a claim, poll `escrow.balances(treasury, 0)` |
| locker collect | hourly check, run when pending is worth more than gas. weekly regardless. the owner of the locker slot is the treasury or its swapper, so rewards stay in the pool until someone collects |
| convert | one per block, paced by the swapper (`minBlocksBetweenConverts`), capped by `maxStepIn` and an impact cap |

## 6. checklist: what the treasury contract must satisfy

| requirement | needed | yes or no |
|---|---|---|
| receives eth by plain transfer within 2,300 gas | no, only for direct bounty pushes. otherwise it pulls from escrow | yes or no |
| no storage write, no cold read, no proxy in `receive()` if it wants direct pushes | yes for direct pushes | yes or no |
| can call `escrow.claim(treasury, 0)` or is callable by a keeper that does | yes if the fallback is heavy | yes or no |
| payable fallback tolerates being triggered by anyone at any time with the claimer gas | yes if selfClaimOnly stays false | yes or no |
| payable fallback does not revert on zero or tiny value | yes, a revert makes claim revert | yes or no |
| calls `setSelfClaimOnly(true)` if only it may trigger the push | optional | yes or no |
| can send `claimTo` to a payable target if it has no payable receive | yes if no payable receive | yes or no |
| accepts the coin by erc20 `transfer`, no callback, no `onERC20Received` | yes if a reward recipient | yes or no |
| does not depend on `streamForward()` being called | yes | yes or no |
| never calls the PoolManager from inside a fee receive path | yes | yes or no |
| is not the hook, the PoolManager or address zero | yes | yes or no |
| reward slot is the treasury, or a `FeeAutoSwapperV2` with `endRecipient = treasury` registered as an escrow depositor | yes | yes or no |
| indexes `FeeDelivered`, `RewardDelivered`, `TokenCreatedV2`, `SkimRefunded`, and the D76 recipient events | yes | yes or no |
| eth only: wraps itself if it wants weth | yes | yes or no |
| config: `bountyBps`, referral cap, `lpFee`, slots pass section 4 limits | yes | yes or no |

note: the locker pushes eth with 150k gas (`PUSH_GAS_MAX`), not the 2,300 stipend, because it never runs inside a swap; the hook legs use the stipend (a zero gas call).
