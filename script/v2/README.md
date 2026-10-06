# script/v2: deploy, launch and verify the v2 stack

no script here reads a private key. sign on the command line with `--ledger`, `--account <keystore>` or `--private-key`. nothing is sent without `--broadcast`. every command uses `FOUNDRY_PROFILE=ci` (optimizer_runs 200): at the default profile `ArtCoinsDeployerV2` is 24,806 bytes, over EIP-170, and the deploy asserts refuse it.

| file | what |
|---|---|
| `DeployV2Lib.sol` | the deploy routine, the post deploy asserts, constructor args. used by the script and by the fork harness (`test/v2/harness/ForkStack.sol` `deployV2Stack`), so tests run the exact broadcast |
| `DeployV2Stack.s.sol` | one broadcast: deploy, wire, hand over, assert, print the registry json, write `tmp/v2-deploy-<chainid>.json` |
| `LaunchV2Coin.s.sol` | `deployTokenAsOwner` from a json config: preflight (wiring, `predictToken`), snapshot dry run, then the tx |
| `launch-configs/example.json` | credits engine style coin: treasury as bounty recipient, tax sink and project slot, VENUE tax at 0, native eth, 69 minute linear skim |
| `deploy.sh` | the deploy wrapper, `deploy.sh <local\|mainnet>`: guards, warm ci build, dry run, broadcast, readback, record, verify. values in `env/<env>.env` |
| `env/local.env`, `env/mainnet.env` | values only: chain id, rpc default, profile, wallet mode, owner, treasury, fee parameters, verify mode. no key or api key |
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
| TREASURY_BPS | 9000 | controller treasury share (Constants allow 4000..9000, the rest burns) |
| REFERRAL_PAYOUT | 0 = the new escrow | factory referral payout. must have code. the escrow has no `notify`, so referral legs are credited to the referrer in the escrow (D16). the live 0xB03C… only accepts the v1 hook |
| DEPLOY_FEE | 0.069 ether | factory deploy fee (wei) |
| PROTOCOL_BPS | 2000 | factory default protocol slot |
| MIN_PROTOCOL_SKIM_SHARE_BPS | 1000 | D52: protocol floor of every skim. caps launch `bountyBps` at `10000 - this` and the referral cap above the floor |
| MIN_LP_FEE | 3000 | D53: launch lp fee floor in pips |

### the wrapper

```
script/v2/deploy.sh <local|mainnet>
```

| step | what |
|---|---|
| values | every required value of `env/<env>.env` is set. `env/mainnet.env` ships with `TREASURY`, `TREASURY_BPS`, `DEPLOY_FEE` and `PROTOCOL_BPS` empty and the wrapper refuses until they are set. `DEPLOY_FEE` is in wei. `REFERRAL_PAYOUT` may stay empty (the v2 escrow) |
| guards | the rpc chain id equals `CHAIN_ID`. `WALLET_MODE=unlocked` needs a loopback rpc and an owner without code (on an anvil fork `cast rpc anvil_setCode <owner> 0x`). `REQUIRE_CLEAN_GIT=true` needs branch `v2` equal to the fetched `origin/v2`, or a tag, and a clean tree |
| build and dry run | `forge build` at profile ci, then `DeployV2Stack.s.sol` with `--sender $OWNER` and no wallet. the dry run must reach `post deploy asserts: ok` |
| broadcast | `--slow` plus `--account <KEYSTORE>` (mainnet) or `--unlocked` (local). the broadcast files go to `BROADCAST_DIR` |
| readback | the broadcast output shows `post deploy asserts: ok`, code at all 10 contracts, factory `deprecated()` true, `deployFee()` equals `DEPLOY_FEE`, escrow, hook, locker and factory owned by or pending to `OWNER` |
| record | `RECORD` (`deployments/1.v2.json` on mainnet, `tmp/v2-local-1.json` on local): `{chainId, repoCommit, owner, stacks, contracts}` in the shape of `deployments/mainnet.json`, with `deployBlock`, `deployTxHash`, `deployedAt` and `source` filled from the broadcast file |
| verify | `VERIFY=full` runs `verify-v2.sh` (explorer sources and chain check), `chain` the chain check only, `none` neither. a pending ownership hand over skips it: run `verify-v2.sh` after the accepts |

`DRY_RUN=1 script/v2/deploy.sh <env>` runs the value and rpc guards (git guards warn), the build and the simulation, with no wallet and no broadcast. `RPC_URL` overrides the env file rpc. secrets come from the shell only: the keystore password is prompted by forge and `ETHERSCAN_API_KEY` is read from the environment.

```
RPC_URL=$ETH_RPC_URL DRY_RUN=1 script/v2/deploy.sh mainnet
script/v2/deploy.sh mainnet
```

the second command signs with the keystore named in `env/mainnet.env` (`ripe0x`). the forge script alone (`FOUNDRY_PROFILE=ci forge script script/v2/DeployV2Stack.s.sol --rpc-url $MAINNET_RPC_URL --sender $OWNER`) is the dry run the wrapper runs, and `forge test --match-path "test/v2/DeployV2Stack.fork.t.sol" --fork-url $MAINNET_RPC_URL -vv` rehearses a broadcaster that differs from OWNER, then accept.

about 29.5m gas over 30 txs (0.011 eth at 0.38 gwei, measured on a fork at block 26131304). the hook goes through the CREATE2 deployer 0x4e59…956C with a salt mined in the script; the salt depends on the broadcaster and the constructor args, so a dry run with `--sender $OWNER` gives the real hook address.

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

`deployments/v2.template.json` is the v2 entry format: a `planned` stack with null addresses (verify-registry accepts planned stacks and skips them in every chain check, and `gen-addresses.mjs` generates no constants for them). after the broadcast, merge the record of step 1:

```
node script-js/merge-v2.mjs deployments/1.v2.json --build
node script-js/verify-registry.mjs --fill --update-blocks
cd script-js && npm run gen:addresses
```

the merge replaces the `v2` stack and its contracts in `deployments/mainnet.json` with the record, sets the status `deployed` (deployed, not yet the live stack; the `current` stack keeps its status), validates the schema and runs `verify-registry.mjs`. `--build` builds every artifact variant first. `--cutover` sets `v2` to `current` and the previous current stack and its contracts to `superseded`. `--file` merges into another registry file.

the generator writes constants per stack id: `CURRENT_*`, `OPEN_*`, `LEGACY_*` and `V2_*` in `script/Addresses.sol`, the objects `CURRENT` and `V2` plus `STACK_ADDRESSES` in `ui/src/lib/deployments.generated.ts`. `ACTIVE_FACTORY`, `ACTIVE_HOOK`, `ACTIVE_LOCKER`, `ACTIVE_ESCROW`, `CURRENT_STACK_ID` and the ts `ACTIVE` follow the stack whose status is `current`.

## 4. launch the first coin (owner only while deprecated)

stack addresses: env `FACTORY_V2 HOOK_V2 LOCKER_V2 MEV_V2`, else `.addresses` of `tmp/v2-deploy-1.json`.

```
cp script/v2/launch-configs/example.json my-coin.json   # edit: treasury placeholder, names, ticks, "example": false

# dry run: preflight, predictToken, snapshot dry run. stops before the tx unless the signer is the factory owner
forge script script/v2/LaunchV2Coin.s.sol --sig "run(string)" "$(cat my-coin.json)" \
  --rpc-url $MAINNET_RPC_URL --sender $OWNER

# send
forge script script/v2/LaunchV2Coin.s.sol --sig "run(string)" "$(cat my-coin.json)" \
  --rpc-url $MAINNET_RPC_URL --ledger --sender $OWNER --broadcast
```

the script prints the predicted token, msg.value (the deploy fee), configHash, the dry run pool id, then the token and pool id. a config with `"example": true` is refused for broadcast (override: `ALLOW_EXAMPLE=true`). `forge script ... LaunchV2Coin.s.sol` with no `--sig` reads `LAUNCH_CONFIG_JSON` (the json text) or the file at `LAUNCH_CONFIG`; reading a file under script/v2 needs `{ access = "read", path = "script/v2/launch-configs" }` in foundry.toml fs_permissions.

config fields map 1:1 to `IArtCoinsFactoryV2.DeploymentConfigV2`; hook, locker and mev module come from the target. not supported by the json: launch extensions, pool extension, tax venues (venues are added later by the venue admin). `protocolBps` is the protocol slot passed to `deployTokenAsOwner`; project `rewardBps` must sum to `10000 - protocolBps`.

after the launch: `BurnRouterV2.initialize(token, key)` if the coin uses the burn leg, add the coin's fee swapper as an escrow depositor (D33), run `ArtCoinsKeeperV2.collectAndForward(token, true, minOut)` once, then `setDeprecated(false)` last (RUNBOOK 2b, 2c).
