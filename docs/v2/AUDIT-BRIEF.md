# artcoins v2: external review brief

## target

| item | value |
|---|---|
| repo | https://github.com/ripe0x/new-material-coin-launcher (private; request read access from the owner) |
| branch | `v2` |
| commit | `f756b1e9d2ba3c349687a5447575f4cd31124d52`, tag `v2-audit-3`. audit the hash, not the branch. earlier targets: `v2-audit-1` = 9fed001, `v2-audit-2` = d8575db |
| pull request | https://github.com/ripe0x/new-material-coin-launcher/pull/35 (draft) |
| toolchain | forge 1.7.1, solc 0.8.26, via ir, `FOUNDRY_PROFILE=ci` (optimizer_runs 200) is what ships; `foundry.toml` |
| chain | ethereum mainnet only, uniswap v4 (PoolManager 0x000000000004444c5dc75cB358380D2e3dE08A90), native eth pairs only |
| status | not deployed. nothing in `src/v2` is on chain. the live stacks under `src/` (v1) are out of scope except as context |

## scope (about 7,900 lines)

| tier | files | why |
|---|---|---|
| 1, highest | `src/v2/hooks/ArtCoinsHookV2.sol`, `src/v2/hooks/libraries/HookCalldata.sol`, `src/v2/ArtCoinsTokenV2.sol`, `src/v2/lp-lockers/ArtCoinsLpLockerV2.sol`, `src/v2/ArtCoinsFeeEscrowV2.sol`, `src/v2/libraries/FeeDelivery.sol` | money on the swap path, transient storage, the restriction allowance, the locked liquidity |
| 2 | `src/v2/ArtCoinsFactoryV2.sol`, `src/v2/utils/ArtCoinsDeployerV2.sol`, `src/v2/mev-modules/ArtCoinsMevLinearSkimV2.sol`, `src/Constants.sol` | launch flow, value accounting, validators, caps |
| 3 | `src/v2/FeeAutoSwapperV2.sol`, `src/v2/protocol-fee/BurnRouterV2.sol`, `src/v2/protocol-fee/ProtocolFeeControllerV2.sol`, `src/v2/extensions/*.sol`, `src/v2/keepers/*.sol` | periphery that holds or moves fees |
| 4, lowest | `src/v2/renderer/*.sol`, `src/v2/interfaces/*.sol` | metadata, no funds |
| out of scope | `src/` v1 contracts, `src/legacy`, `script/`, `ui/`, `lib/` | v1 is live and immutable; reviewed separately (docs/v2/SYSTEM-REVIEW.md sections 3 and 4) |

## what the system is

a token launcher: the factory deploys an erc20 (solady) via a CREATE2 deployer, seeds a uniswap v4 pool paired with native eth, places the pool supply as locked liquidity in the locker, and installs a shared hook that skims a share of every swap and splits it three ways (bounty recipient, protocol, referrer), with an anti sniper skim that decays over a window. per coin config (fees, recipients, lock) is written once at launch and has no writer afterwards. the factory side (allowlists, escrow, modules, periphery) is owner changeable by a single eoa (no multisig, no timelock, by design). one optional launch flag, `restricted` (D73): while set, holder to holder transfers revert unless a side is on the coin allowlist, and coin moves to or from the PoolManager only within the transient allowance the canonical hook grants for a canonical swap in the same transaction. the coin admin manages the allowlist, may turn restriction off once, and may lock the allowlist and the switch permanently. docs/v2/DESIGN.md has the component map and docs/v2/DECISIONS.md (D1 to D73) every deliberate choice.

## invariants to attack (the claims we make)

| # | claim |
|---|---|
| i1 | fee legs are pushed with a zero gas call, so the recipient runs only on the evm's 2,300 gas stipend; it can read state and call `PoolManager.sync`, nothing else; the hook resets sync after the pushes; revert, gas burn and returndata are contained by the escrow fallback; an erc20 prepay style router that syncs before the swap must be tested before being declared supported. no recipient behavior can revert or reorder a swap or spend another user's exemption (amended by D60) |
| i2 | the hook holds no eth and no erc6909 claims after every swap; the skim on price limited partial fills is charged on the realized amount, the over charge is credited in the escrow to the refund address in hookData (else the PoolManager caller); returned BalanceDelta equals the transient delta for every router |
| i3 | the referral leg never takes the protocol leg below `minProtocolShareBps` of the baseline skim; every wei of a skim is accounted to exactly one of bounty, protocol, referral, refund |
| i4 | restriction (D73): while a coin is `restricted`, a transfer passes only if it is a mint or burn, if either side is on the coin allowlist, or if one side is the PoolManager and the amount fits the transient allowance the canonical hook grants for a canonical swap this transaction, which the transfer consumes; else it reverts `TransferRestricted`. When not restricted every transfer passes. `restricted` never turns back on; the coin admin may `unrestrict` once and `lock` the allowlist and the switch permanently |
| i5 | a restricted coin's allowance is granted only by the canonical hook, equal to the coin side of each swap, so coin leaves the PoolManager to a non allowlisted holder only within allowance created by canonical swap volume in the same transaction (D74: unused allowance from canonical swaps can fund another PoolManager flow; moving X wallet to wallet needs 2X of canonical coin volume). the PoolManager and the canonical hook cannot be allowlisted, at launch or by the admin. `_restriction` seeds the allowlist with: the owner `defaultAllowed` set (empty by default), this launch's locker, the stack fee escrow, and the launch extensions; it marks the locker, escrow and extensions pinned (the coin admin cannot remove them). the fee swapper and burn router are not seeded: they sell or buy coin through the canonical pool under the per swap allowance, and receive coin from the allowlisted locker. the allowlist holds only contracts whose coin outflows are fixed by their own logic; a contract that sends coin where its caller directs (a router, aggregator, multicall or smart wallet) is a prohibited entry, because the transfer rule checks the two parties only, so an allowlisted forwarder would let any user move coin wallet to wallet through it. the standard routers are not allowlisted: a restricted coin trades through the universal router and permit2 with neither on the list, because the only coin move is between the PoolManager and the user |
| i6 | restriction is fee priced, not absolute (D73, accepted): a canonical buy and sell of X in one transaction grant 2X of the undirected transfer allowance and consume none, so within that transaction a holder can move X through PoolManager balance operations (settle, mint a claim, transfer a claim, take, burn) or add X of coin liquidity. moving coin outside the home pool therefore costs a canonical round trip (the home pool's two way fees); the coins the move produces are still restricted (a later wallet to wallet send reverts) |
| i7 | the locker's `collectRewards` cannot be executed inside a foreign unlock, measures fees from its own balance deltas, and recipients and bps are frozen per coin |
| i8 | the escrow never pays out more than `totalOwed`, the owner's rescue cannot reach owed balances, core depositors cannot be removed, `selfClaimOnly` is honoured |
| i9 | the token address binds `(factory, sender, full config hash)`; a front runner cannot block or capture a launch; the factory refunds exactly the excess and holds no coin after a launch |
| i10 | the burn router burns at most once per block within `maxImpactBps` and `maxBurnPerCall`; the swapper's convert is bounded the same way; neither can be bricked by a donation or by a floor that can never be met (fee aware floor) |
| i11 | exact split of immutable and mutable state, see the table below this one. after D61 every bounded setter in `src/v2` reads its bounds from `Constants` (one technical exception, see the table); `constantsHash()` agrees across the stack (`Constants.hash()` covers the cross contract values only, the burn router per call bounds are not hashed) |
| i12 | no contract exceeds 24,576 bytes at the ci profile (the hook is 16,716 with 7,860 headroom) |

### i11 detail: immutable vs mutable

| class | what | who can change it |
|---|---|---|
| immutable per coin | name, symbol, supply, canonical pool binding, the launch value of `restricted`, pool skim config and recipients, locker slots and bps, mev schedule | nobody, written once in the launch tx, no setter |
| mutable, token admin | `restricted` (off once, via `unrestrict`), the allowlist (`setAllowed`), `locked` (on once, via `lock`), metadata, image, renderer, admin | the coin's token admin; `unrestrict`, `setAllowed` and `lock` revert once locked |
| mutable, owner on periphery | every setter on the factory, hook, locker, escrow, swapper, burn router and fee controller | the owner, every setter bounded by `Constants` (D61: the burn router per call cap bounds moved there). one exception: `FeeAutoSwapperV2.setMaxStepIn` is bounded by the contract local `MAX_STEP_IN_CEILING` (`type(int128).max`, the v4 amount type limit) |


## known residuals (do not spend time re finding; do tell us if they are worse than we think)

| id | residual |
|---|---|
| ACV2-04-02 | coin sent to `ArtCoinsKeeperV2` on a restricted coin stays there: the keeper is ownerless and skips the coin forward. coin reaches it only when a launch names the keeper as a reward recipient (launcher misconfiguration, same class as V2F-07) or someone buys to it |
| D73 | restriction is fee priced, not absolute: a canonical buy and sell of X in one transaction grant 2X allowance and consume none, so a holder can move X wallet to wallet through PoolManager balance operations (settle, mint or transfer a claim, take, burn) or add X of coin liquidity, at the cost of the home pool's round trip fees. the coins produced stay restricted. `RestrictionRouterV2.test_restricted_roundTrip_feePriced` documents the move and its cost |
| V2H-06 | an exact out seller's eth delta can be negative until the escrow refund is claimed (positive net of it) |
| V2H-03 | universal router swaps that omit a refund address in hookData leave the partial fill refund credited to the router in the escrow (the ui sets it) |
| V2H-07 | the hook constructor cannot verify it is a core escrow depositor; the deploy script asserts it |
| h1-notes | a stipend recipient can read state and call `PoolManager.sync`, nothing else; the hook resets sync after the pushes; an erc20 prepay style router that syncs before the swap must be tested before being declared supported |
| h1-notes | owner enabled extensions run between liquidity placement and arming and could add liquidity in that window (trusted) |
| V2A-09 | the PoolManager transfer allowance is per transaction, so an erc4337 bundle shares it across user ops on a restricted coin |
| D54 | resolved under D73: the heaviest launch config now fits under the per tx gas cap (retiring the tax config removed the venue and exempt processing) |
| D55 | `setTokenDeployer` is an owner trust surface by design |
| D73 / predict | a restricted coin's token address (and its seeded allowlist) depend on the factory `defaultAllowed` set and the launch hook's fee escrow, both owner settable; the owner changing either between a `predictToken` read and the launch changes the address the launch produces (owner trust, accepted, same class as `setTokenDeployer`) |
| D44 | self referral through a router is accepted and bounded by the frozen cap and the protocol floor |
| D70 | a token whose `transfer` returns false or 1 to 31 bytes reverts `FeeDelivery.sendErc20` (`InvalidTransferReturn`); a blocklist style token therefore reverts `ProtocolFeeControllerV2.processFees(token)` for that token |

## what already exists (use it, do not redo it)

| item | where |
|---|---|
| two internal review passes with proof tests (38 findings on v2, all medium and above fixed with regressions) | docs/v2/review/v2-review-{a,b,hook,factory}.md, test/v2/review-v2/ |
| the package authors' own residual notes | docs/v2/review/h1-notes.md, t1-notes.md, s1-notes.md, i1-notes.md |
| the v1 review that motivated v2 (what the live stack gets wrong) | docs/v2/SYSTEM-REVIEW.md |
| the deploy routine the auditor should read as the wiring spec | script/v2/DeployV2Lib.sol, script/v2/README.md |
| test harness on a mainnet fork at block 26130269 | test/v2/harness/ForkBase.sol, ForkStack.sol; integration suite test/v2/integration/ |

## how to build and run

```
git clone https://github.com/ripe0x/new-material-coin-launcher && cd new-material-coin-launcher && git checkout v2-audit-3
git submodule update --init --recursive
export MAINNET_RPC_URL=<keyed mainnet rpc>   # the tenderly public gateway works but rate limits
FOUNDRY_PROFILE=ci forge build --sizes --skip "test/**" --skip script
FOUNDRY_PROFILE=ci forge test --match-path "test/v2/**" --fork-url $MAINNET_RPC_URL --fork-block-number 26130269 --fork-retries 8 --fork-retry-backoff 2000
```
expected at `v2-audit-3`: 364 pass on the fork plus 238 unit tests without a fork (`forge test --match-path "test/v2/**" --match-contract "^(EscrowV2Test|FeeDeliveryTest|TokenV2Test|ConstantsV2Test|MevLinearSkimV2Test|KeeperV2Test|ProtocolFeeControllerV2Test|RendererV2Test|AirdropV2Test|VaultV2Test)$"`). a cold compile of the whole tree needs about 14 gb; the commands above skip the v1 test tree.

## deliverable we want

| item |
|---|
| findings with severity, a runnable proof (forge test on the fork harness) for anything medium or above, and a recommended fix |
| a verdict per invariant i1 to i12: holds, holds with caveat, broken |
| anything in the known residuals you consider higher severity than we do |
| gas and size observations on the swap hot path (buy 142k, sell 161k cold on our measurements) |
| no need to review v1, scripts, ui, docs prose, or style |

## contacts and process

| item | value |
|---|---|
| owner | the repo owner (single eoa, 0xCB43078C32423F5348Cab5885911C3B5faE217F9, will be the contract owner) |
| fixes | we fix on `v2`, tag the next target `v2-audit-4`, and ask for a re check of changed files only |
| disclosure | keep findings private to the owner. v2 is not deployed; findings on the live v1 contracts go to the owner first |
