# s1 notes: v2 deploy and verify tooling

files: `script/v2/DeployV2Lib.sol`, `script/v2/DeployV2Stack.s.sol`, `script/v2/LaunchV2Coin.s.sol`, `script/v2/launch-configs/example.json`, `script/v2/verify-v2.sh`, `script/v2/README.md`, `test/v2/DeployV2Stack.fork.t.sol`, `test/v2/harness/ForkStack.sol` (`deployV2Stack`, `acceptV2Ownership`, `v2DefaultParams`), `deployments/v2.template.json`, `script-js/verify-registry.mjs` (planned stacks, v2 escrow depositor getter), RUNBOOK part 2a.

| item | decision |
|---|---|
| one routine | `DeployV2Lib.deploy` runs in the script (inside `vm.startBroadcast()`) and in the harness (inside `vm.startPrank(broadcaster)`). `DeployV2Lib.check` is the post deploy assert set for both |
| order change | burn router before the controller: the controller constructor rejects a zero router |
| owners | escrow, hook, locker, factory: built with the broadcaster (it wires them), then `transferOwnership(OWNER)` when they differ. allowlist, router, controller: built with OWNER (no deploy time owner call) |
| referral payout | the escrow by default. live 0xB03C… reverts `Unauthorized()` (0x82b42900) for any caller but the v1 hook 0x636c (eth_call); the owner eoa has no code and the hook's init requires code |
| profile | ci only. `ArtCoinsDeployerV2` is 24,806 bytes at the default profile (D45). the harness enforces EIP-170 only under FOUNDRY_PROFILE=ci |
| hook salt | own search loop with the init code hash computed once and code read only on a match (HookMiner.find reads code per candidate, one rpc call each on a fork); formula cross checked with `HookMiner.computeAddress` |
| D52, D53 | `setMinProtocolSkimShareBps(1000)`, `setMinLpFee(3000)` in the wiring |
| registry | v2 is not in mainnet.json: `gen-addresses.mjs` expects one `current` stack named `current` and dies on null dates. template in `deployments/v2.template.json` (status planned) |

open: foundry.toml fs_permissions has no read entry for `script/v2/launch-configs`, so `LaunchV2Coin.run()` with a file path and the test's file read fail; `run(string)` and `LAUNCH_CONFIG_JSON` work, the test falls back to an embedded copy. add `{ access = "read", path = "script/v2/launch-configs" }` to enable both.
