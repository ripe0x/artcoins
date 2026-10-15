# script/v2: deploy, launch and verify the v2 stack

sign on the command line with `--ledger`, `--account <keystore>` or `--private-key`. transactions are sent with `--broadcast`. every command uses `FOUNDRY_PROFILE=ci` (optimizer_runs 200): at the default profile `ArtCoinsDeployerV2` is 24,806 bytes, over EIP-170, and the deploy asserts refuse it.

| file | what |
|---|---|
| `DeployV2Lib.sol` | the deploy routine, the post deploy asserts, constructor args. used by the script and by the fork harness (`test/v2/harness/ForkStack.sol` `deployV2Stack`), so tests run the exact broadcast |
| `DeployV2Stack.s.sol` | one broadcast: deploy, wire, hand over, assert, print the registry json, write `tmp/v2-deploy-<chainid>.json` |
| `LaunchV2Coin.s.sol` | `factory.deployToken` from a json config (the owner may call it while the factory is deprecated): preflight (wiring, `predictToken`), snapshot dry run, then the tx |
| `launch-configs/example.json` | credits style coin with the treasury as bounty recipient, not restricted (plain erc20), native eth, 69 minute linear skim |
| `launch-configs/example-devbuy.json` | the same coin with a 0.01 eth dev buy in the `extensions` array |
| `launch-configs/example-vault.json` | the same coin with a 10% vault allocation (7 day cliff, 90 day vesting) in the `extensions` array |
| `deploy.sh` | the deploy wrapper, `deploy.sh <local\|mainnet>`: guards, warm ci build, dry run, broadcast, readback, record, verify. values in `env/<env>.env` |
| `env/local.env`, `env/mainnet.env` | values only: chain id, rpc default, profile, wallet mode, owner, treasury, fee parameters, verify mode. secrets come from the shell |
| `verify-v2.sh` | `forge verify-contract` for every contract, then the chain check (runtime vs local ci build, owners, wiring) |
| `RunKeeper111.s.sol` | coin 111 keeper (v1 stack), unrelated to the v2 deploy |

## setup

```
export MAINNET_RPC_URL=${MAINNET_RPC_URL:-https://mainnet.gateway.tenderly.co}
export OWNER=0xCB43078C32423F5348Cab5885911C3B5faE217F9   # Addresses.OWNER, the default
export FOUNDRY_PROFILE=ci
```

## 1. deploy

| env (optional) | default | meaning |
|---|---|---|
| OWNER | `Addresses.OWNER` | owner of every owned contract, team fee recipient |
| TREASURY | OWNER | `ProtocolFeeControllerV2` treasury |
| TREASURY_BPS | 8000 | controller treasury share (Constants allow 1000..9000, the rest buys and burns LAYER); owner tunable with `setSplit` |
| DEPLOY_FEE | 0 | factory deploy fee (wei); owner tunable later with `setDeployFee` |
| REFERRAL_BPS | 25 | hook wide referral rate, bps of swap volume, paid to a swap's named referrer out of the protocol leg; owner tunable with `hook.setReferralBps` up to 100 (1%) |

### the wrapper

```
script/v2/deploy.sh <local|mainnet>
DRY_RUN=0 script/v2/deploy.sh <local|mainnet>
```

`DRY_RUN` is 1 unless set. 1 is simulation only and any value other than 0 or 1 is refused. 0 broadcasts.

| step | what |
|---|---|
| values | every required value of `env/<env>.env` is set. the wrapper refuses while any required value of the env file is empty. `DEPLOY_FEE` is in wei. |
| guards | the rpc chain id equals `CHAIN_ID`. `WALLET_MODE=unlocked` needs a loopback rpc host that answers `anvil_nodeInfo` and an owner without code (on an anvil fork `cast rpc anvil_setCode <owner> 0x`). `REQUIRE_CLEAN_GIT=true` fetches `origin master` and needs HEAD equal to `origin/master`, or a tag that `git ls-remote` shows on origin at HEAD, and a clean tree. the git guards warn on a simulation and refuse on a broadcast |
| build and simulation | `forge build` at profile ci, then `DeployV2Stack.s.sol` with `--sender $OWNER`. it must reach `post deploy asserts: ok` |
| signer | `WALLET_MODE=account`: `cast wallet address --account $KEYSTORE` equals `OWNER`, then the operator types the last 6 hex digits of `OWNER` at the terminal |
| broadcast | `--slow` plus `--account <KEYSTORE>` (mainnet) or `--unlocked` (local). the broadcast files go to `BROADCAST_DIR` |
| readback | `post deploy asserts: ok` in the broadcast output, code at all 12 contracts, factory `deprecated()` true, `deployFee()` equals `DEPLOY_FEE`, escrow, hook, locker and factory owned by or pending to `OWNER` |
| record | `RECORD` (`deployments/1.v2.json` on mainnet, `tmp/v2-local-1.json` on local): `{chainId, repoCommit, owner, ownershipPending, stacks, contracts}` in the shape of `deployments/mainnet.json`, with `deployBlock`, `deployTxHash`, `deployedAt` and `source` filled from the broadcast file. the file must belong to the run: same chain and commit, one receipt per transaction, every status 0x1, created within 10 minutes of `tmp/v2-deploy-1.json` |
| verify | `VERIFY=full` runs `verify-v2.sh` (explorer sources and chain check), `chain` the chain check only, `none` neither. after a passing check the record is rewritten with `bytecodeMatch` verified and `ownershipPending` false |

the rpc url travels in `ETH_RPC_URL` (cast) and `FOUNDRY_ETH_RPC_URL` (forge), and every message shows scheme and host only. `RPC_URL` overrides the env file rpc. secrets come from the shell: forge prompts for the keystore password and reads `ETHERSCAN_API_KEY` from the environment.

```
RPC_URL=$ETH_RPC_URL script/v2/deploy.sh mainnet
RPC_URL=$ETH_RPC_URL DRY_RUN=0 script/v2/deploy.sh mainnet
```

the second command signs with the keystore named in `env/mainnet.env` (`ripe0x`). the forge script alone (`FOUNDRY_PROFILE=ci forge script script/v2/DeployV2Stack.s.sol --sender $OWNER`) is the simulation the wrapper runs, and `forge test --match-path "test/v2/DeployV2Stack.fork.t.sol" --fork-url $MAINNET_RPC_URL -vv` rehearses a broadcaster that differs from OWNER, then accept.

### recovery after a partial broadcast

the owner `0xCB43…17F9` carries an EIP-7702 delegation (code `0xef0100…`): a delegated account has one transaction in flight and a nonce gap is rejected. `--slow` waits for each receipt. when a broadcast stops part way:

1. read the signer nonce: `cast nonce $OWNER`. it must equal the nonce recorded in `broadcast/DeployV2Stack.s.sol/1/run-latest.json` for the last sent transaction plus one.
2. nonce unchanged since the failure: `FOUNDRY_PROFILE=ci forge script script/v2/DeployV2Stack.s.sol --sender $OWNER --account ripe0x --broadcast --resume --slow` sends only the unsent transactions with the original constructor arguments.
3. nonce moved: the sequence differs from the saved file. start a new deployment and treat the landed contracts as a separate stack.

then rerun the wrapper steps from the readback on: `node script-js/v2-record.mjs tmp/v2-deploy-1.json broadcast/DeployV2Stack.s.sol/1/run-latest.json deployments/1.v2.json`.

the wrapper prints the gas limit of each transaction and the total before any keystore prompt. the hook goes through the CREATE2 deployer 0x4e59…956C with a salt mined in the script; the salt depends on the broadcaster and the constructor args, so a dry run with `--sender $OWNER` gives the real hook address. the low 14 bits of the hook address equal `0x28CC`: the address ends in `28cc`, `68cc`, `a8cc` or `e8cc`.

order and args: docs/v2/RUNBOOK.md part 2a. the factory ships `deprecated = true`.

### when the broadcaster is not OWNER

the escrow, hook, locker and factory end with `owner() == broadcaster` and `pendingOwner() == OWNER`. the allowlist, burn router and controller are constructed with OWNER. OWNER then sends, one at a time:

```
J=tmp/v2-deploy-1.json
for k in escrow hook locker factory; do
  a=$(jq -r ".addresses.$k" $J)
  cast call --from $OWNER $a "acceptOwnership()" --rpc-url $MAINNET_RPC_URL     # simulate
  cast send $a "acceptOwnership()" --rpc-url $MAINNET_RPC_URL --ledger            # send
  cast call $a "owner()(address)" --rpc-url $MAINNET_RPC_URL                       # == OWNER
done
```

until all four are accepted the broadcaster keeps owner powers. do this before anything else.

## 2. verify

```
script/v2/verify-v2.sh                    # etherscan if ETHERSCAN_API_KEY is set, else blockscout, then chain check
script/v2/verify-v2.sh --dry-run          # print the forge verify-contract commands
script/v2/verify-v2.sh --skip-source      # chain check only
```

the chain check writes a one stack registry from the json and runs `script-js/verify-registry.mjs` on it with the artifacts of a fresh ci build (`foundry-out-ci`). it fails on a runtime mismatch, an owner other than OWNER (run it after `acceptOwnership`), a missing escrow depositor, or a factory that is no longer deprecated (rerun with an edited json after opening). the hook is always verified as `src/v2/hooks/ArtCoinsHookV2.sol:ArtCoinsHookV2`: `src/hooks/legacy/ArtCoinsHookV2.sol` has the same contract name.

## 3. registry

`deployments/v2.template.json` is the v2 entry format: a `planned` stack with null addresses (verify-registry skips planned stacks in every chain check and `gen-addresses.mjs` generates no constants for them). after the broadcast, merge the record of step 1:

```
node script-js/merge-v2.mjs deployments/1.v2.json --build
node script-js/verify-registry.mjs --fill --update-blocks
cd script-js && npm run gen:addresses
```

the merge overlays the record on the `v2` stack entry and replaces the stack's contracts. a `v2` entry that is `current` (the 2026-10-09 stack) keeps status `current` and is replaced in place: addresses and contracts become those of the record, and no separate superseded entry remains. a `v2` entry that is `planned` or `deployed` gets status `deployed` and the `current` stack keeps its status. run `npm run gen:addresses` after the merge to regenerate the `V2_*` constants. the schema check and `verify-registry.mjs` run on a temporary file, and the registry is replaced only when both pass. `--build` builds every artifact variant first. `--file` merges into another registry file.

| command | effect |
|---|---|
| `merge-v2.mjs <record> --cutover` | v2 becomes `current`, the previous current stack and its contracts become `superseded`, `stacks.v2.replaces` holds the previous id. needs a record with every contract `verified` and `ownershipPending` false. repeating it changes nothing |
| `merge-v2.mjs <record>` while v2 is `current` | v2 stays `current`, its addresses and contracts are replaced by the record |
| `merge-v2.mjs --rollback` | the stack named in `stacks.v2.replaces` is `current` again and v2 is `deployed` |

the generator writes constants per stack id: `CURRENT_*` (the `0x4959` stack, v1 abi), `OPEN_*`, `LEGACY_*` and `V2_*` in `script/Addresses.sol`, and `CURRENT` and `V2` in `abi/deployments.generated.ts`. v2 consumers read `V2_*` and `V2`. scripts and site code that bind the v1 abi of the `0x4959` stack read `CURRENT_*`.

## 4. launch the first coin (owner only while deprecated)

stack addresses: env `FACTORY_V2 HOOK_V2 LOCKER_V2 MEV_V2` (plus `DEV_BUY_V2 AIRDROP_V2 VAULT_V2` for configs that use the `devBuy`, `airdrop` and `vault` keys), else `.addresses` of `tmp/v2-deploy-1.json`.

```
cp script/v2/launch-configs/example.json my-coin.json   # edit: treasury placeholder, names, ticks, "example": false

# dry run: preflight, predictToken, snapshot dry run. stops before the tx unless the signer is the factory owner
forge script script/v2/LaunchV2Coin.s.sol --sig "run(string)" "$(cat my-coin.json)" \
  --rpc-url $MAINNET_RPC_URL --sender $OWNER

# send
forge script script/v2/LaunchV2Coin.s.sol --sig "run(string)" "$(cat my-coin.json)" \
  --rpc-url $MAINNET_RPC_URL --ledger --sender $OWNER --broadcast
```

the script prints the predicted token, msg.value (the deploy fee plus the sum of the extension `msgValue` entries), the extension count, configHash, the dry run pool id, then the token and pool id. a config with `"example": true` is refused for broadcast (override: `ALLOW_EXAMPLE=true`). `forge script ... LaunchV2Coin.s.sol` with no `--sig` reads `LAUNCH_CONFIG_JSON` (the json text) or the file at `LAUNCH_CONFIG`; reading a file under script/v2 needs `{ access = "read", path = "script/v2/launch-configs" }` in foundry.toml fs_permissions.

config fields map 1:1 to `IArtCoinsFactoryV2.DeploymentConfigV2`; hook, locker and mev module come from the target. `restriction.restricted` is a bool; when true, list extra allowlist entries in `restriction.allowed` (the factory seeds this launch's locker and the launch extensions on top). `extensions` is an optional array of launch extensions. a pool extension is outside the json. the launch call is `deployToken`; while the factory is deprecated only the owner may call it.

### launch extensions

the stack deploys and enables `ArtCoinsUniv4EthDevBuyV2`, `ArtCoinsAirdropV2` and `ArtCoinsVaultV2` (contracts 10, 11 and 12, `factory.setExtension(addr, true)`).

each `extensions` entry is `{"extension", "bps", "msgValue", "data"}` and maps to `ExtensionConfigV2{extension, msgValue, extensionBps, extensionData}`:

| field | meaning |
|---|---|
| `extension` | an address, or the key `devBuy`, `airdrop` or `vault` (the stack's instances, from `DEV_BUY_V2` / `AIRDROP_V2` / `VAULT_V2` or the deploy record). it must be enabled on the factory |
| `bps` | share of total supply, uint16. the sum over all entries is at most 9,000 and at most 10 entries |
| `msgValue` | wei forwarded to the extension. `deployToken` needs `msg.value` of at least `deployFee + sum(msgValue)`, the script sends exactly that and the factory refunds any excess |
| `data` | hex of the abi encoded `extensionData` |

| extension | `bps` | `msgValue` | `data` |
|---|---|---|---|
| dev buy | 0 | nonzero, the eth spent on the buy | `abi.encode(address recipient, address refundRecipient, uint128 minOut)`, 96 bytes. `recipient` receives the coin, `refundRecipient` receives unspent eth and the hook's refund credit of a partial fill, `minOut` is the nonzero minimum coin out computed from the pool curve (the buy pays the baseline skim) |
| airdrop | nonzero | 0 | `abi.encode(address sweepRecipient, bytes32 merkleRoot, uint256 lockup, uint256 vesting)`, 128 bytes. lockup and vesting in seconds, each at most 3650 days. leaves are `keccak256(bytes.concat(keccak256(abi.encode(address, uint256))))` (OpenZeppelin StandardMerkleTree, types `["address","uint256"]`); the sum of leaf amounts stays at or below `totalSupply * bps / 10000`. claims open at lockup end and the tranche is swept 14 days after vesting ends |
| vault | nonzero | 0 | `abi.encode(address beneficiary, uint256 lockup, uint256 vesting)`, 96 bytes. lockup is the cliff and vesting the linear period after it, in seconds: lockup at least 7 days, vesting at least 90 days, each at most 3650 days. the beneficiary is nonzero and is not the coin or the vault. `claim(token, index)` is callable by anyone, reverts before lockup end and pays the beneficiary. `launch-configs/example-vault.json` is the vault example |

encode `data` with `cast abi-encode "f(address,address,uint128)" <recipient> <refundRecipient> <minOut>`. `launch-configs/example-devbuy.json` is the dev buy example. extensions run before the mev module starts, so the dev buy pays the pool baseline skim.

pools charge no lp fee: `fee.baselineSkimBps` (above 0, at most 10%) is the only trading fee, and the coin admin may lower it later. the protocol leg is the skim share above `bountyBps`, with the hook wide referral carved from it.

anti sniper window split: while the mev module is active (the first `windowSeconds`, capped at 180 minutes), the hook charges `startingSkimBps` decaying to `baselineSkimBps`. The baseline portion of the skim splits bounty / protocol / referral as configured; the skim ABOVE the baseline goes entirely to the bounty recipient. Measured for a 0.1 eth in-window buy on the example config (start 68,690, baseline 6,000, bounty 8,333 bps): total skim 0.06869 eth, baseline portion 0.006 eth, bounty leg 0.0676898 eth, protocol leg 0.0010002 eth. The 0.06269 eth above the baseline is all bounty. The coin admin may repoint the bounty recipient after launch with `hook.setBountyRecipient` until `token.lock()` or admin renounce.

recipient changes after launch: `hook.setBountyRecipient(poolId, recipient)` is coin admin only; the hook checks the new recipient: nonzero, and not the coin, the hook, the PoolManager, the factory, the token deployer, the pool's mev module, locker or pool extension, the locker's PositionManager, a fee escrow the hook has had or an extension the factory has ever enabled. a recipient that cannot take the 2,300 gas push is credited in the escrow. `bountyBps` stays fixed. `token.lock()` freezes the setter one way, and renouncing the coin admin freezes them.

allowlist rule (restricted coins): the transfer rule checks the sender and the recipient only. the factory seeds the allowlist with this launch's locker and the launch extensions; the coin admin may add and remove entries until `lock()`, and removing the locker is the admin's own loss. the burn router is not seeded: it moves LAYER, never a v2 coin. allowlist a contract ONLY when its coin outflows are fixed by its own logic (the locker holds positions; an airdrop or vault pays its configured recipients). never allowlist a contract that sends coin where its caller directs it: a router, aggregator, multicall or smart wallet. an allowlisted forwarder lets any user move coin wallet to wallet through it, which opens restriction for everyone. a restricted coin already trades through the universal router and permit2 with neither allowlisted, because the only coin move is between the PoolManager and the user.

restriction is fee priced, not absolute: a canonical buy and sell of X in one transaction grant 2X of the transfer allowance and consume none, so a holder can move X wallet to wallet through PoolManager balance operations or add X of coin liquidity, at the cost of the home pool's round trip fees. the coins produced stay restricted. restriction raises the cost of leaving the home pool; it does not pin supply.

after the launch: a small buy and sell, check the bounty and protocol legs landed (the protocol leg normally reaches the payable controller by the 2,300 gas push; the escrow holds the credit of a failed push, and `controller.processFees()` claims it before splitting the balance), then `setDeprecated(false)` last (RUNBOOK 2b, 2c). no per coin keeper exists: the skim is pushed per swap and the burn router is bound to LAYER at deploy.
