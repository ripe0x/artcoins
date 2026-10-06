# v2 contract sizes (ci profile)

command: `FOUNDRY_PROFILE=ci /tmp/claude-0/forge.sh build --sizes --skip "test/**" --skip script` (optimizer_runs 200, viaIR, same as `[profile.ci]` and the ci workflow). json: same command with `--json`. date 2026-10-06, foundry 1.7.1, solc 0.8.26.

limits: runtime 24,576 bytes (EIP-170), initcode 49,152 bytes (EIP-3860). margin = limit minus size.

| contract | file | runtime | initcode | runtime margin | initcode margin |
|---|---|---|---|---|---|
| ArtCoinsDeployerV2 | `src/v2/utils/ArtCoinsDeployerV2.sol` | 21,166 | 21,319 | 3,410 | 27,833 |
| ArtCoinsFactoryV2 | `src/v2/ArtCoinsFactoryV2.sol` | 19,593 | 20,236 | 4,983 | 28,916 |
| ArtCoinsHookV2 | `src/v2/hooks/ArtCoinsHookV2.sol` | 16,716 | 18,695 | 7,860 | 30,457 |
| ArtCoinsLpLockerV2 | `src/v2/lp-lockers/ArtCoinsLpLockerV2.sol` | 13,590 | 14,977 | 10,986 | 34,175 |
| ArtCoinsTokenV2 | `src/v2/ArtCoinsTokenV2.sol` | 12,691 | 18,265 | 11,885 | 30,887 |
| BurnRouterV2 | `src/v2/protocol-fee/BurnRouterV2.sol` | 9,342 | 10,009 | 15,234 | 39,143 |
| DynamicBlockRendererV2 | `src/v2/renderer/DynamicBlockRendererV2.sol` | 9,247 | 9,273 | 15,329 | 39,879 |
| FeeAutoSwapperV2 | `src/v2/FeeAutoSwapperV2.sol` | 9,158 | 11,471 | 15,418 | 37,681 |
| ExampleOnChainRendererV2 | `src/v2/renderer/ExampleOnChainRendererV2.sol` | 8,470 | 8,496 | 16,106 | 40,656 |
| SpriteRendererV2 | `src/v2/renderer/SpriteRendererV2.sol` | 7,188 | 7,795 | 17,388 | 41,357 |
| CollectFlushKeeperV1 | `src/v2/keepers/CollectFlushKeeperV1.sol` | 4,630 | 4,919 | 19,946 | 44,233 |
| DefaultMetadataRendererV2 | `src/v2/renderer/DefaultMetadataRendererV2.sol` | 4,572 | 4,598 | 20,004 | 44,554 |
| ArtCoinsAirdropV2 | `src/v2/extensions/ArtCoinsAirdropV2.sol` | 4,068 | 4,258 | 20,508 | 44,894 |
| ProtocolFeeControllerV2 | `src/v2/protocol-fee/ProtocolFeeControllerV2.sol` | 3,935 | 4,707 | 20,641 | 44,445 |
| ArtCoinsFeeEscrowV2 | `src/v2/ArtCoinsFeeEscrowV2.sol` | 3,883 | 4,101 | 20,693 | 45,051 |
| ArtCoinsUniv4EthDevBuyV2 | `src/v2/extensions/ArtCoinsUniv4EthDevBuyV2.sol` | 3,799 | 4,084 | 20,777 | 45,068 |
| ArtCoinsKeeperV2 | `src/v2/keepers/ArtCoinsKeeperV2.sol` | 3,371 | 3,524 | 21,205 | 45,628 |
| ArtCoinsVaultV2 | `src/v2/extensions/ArtCoinsVaultV2.sol` | 2,922 | 3,111 | 21,654 | 46,041 |
| ArtCoinsMevLinearSkimV2 | `src/v2/mev-modules/ArtCoinsMevLinearSkimV2.sol` | 2,472 | 2,625 | 22,104 | 46,527 |
| HookCalldata (library) | `src/v2/hooks/libraries/HookCalldata.sol` | 3 | 31 | 24,573 | 49,121 |
| FeeDelivery (library) | `src/v2/libraries/FeeDelivery.sol` | 3 | 31 | 24,573 | 49,121 |
| TaxVenues (library) | `src/v2/libraries/TaxVenues.sol` | 3 | 31 | 24,573 | 49,121 |
| SvgText (library) | `src/v2/renderer/SvgText.sol` | 3 | 31 | 24,573 | 49,121 |

## gates

| gate | result |
|---|---|
| hook runtime headroom >= 1,024 | pass: ArtCoinsHookV2 16,716 bytes, headroom 7,860 |
| no src/v2 contract over 24,576 runtime | pass: largest is ArtCoinsDeployerV2 at 21,166 (margin 3,410) |
| no src/v2 contract over 49,152 initcode | pass: largest initcode is ArtCoinsDeployerV2 at 21,319 |

## ci size gate (fixed)

`src/hooks/legacy/ArtCoinsHookV2.sol` and `src/v2/hooks/ArtCoinsHookV2.sol` share the contract name, so forge keys the `--json` output by `ArtCoinsHookV2 (src/v2/hooks/ArtCoinsHookV2.sol)`. the old gate tested `has("ArtCoinsHookV2")`, which is false, so it printed `size gate skipped` and exited 0: the 1,024 byte rule was not enforced.

now (`.github/workflows/test.yml`, step `Size gate, ArtCoinsHookV2 headroom`): builds with `--json --skip "test/**" --skip script`, selects the key with `startswith("ArtCoinsHookV2") and contains("src/v2/hooks/ArtCoinsHookV2.sol")`, fails when there is not exactly one match (no more silent skip) and fails when `runtime_margin` is under 1,024 or not a number.

proof, the step's shell run locally under `FOUNDRY_PROFILE=ci` with the wrapper standing in for `forge`:

| case | output | exit |
|---|---|---|
| real | `ArtCoinsHookV2 (src/v2/hooks/ArtCoinsHookV2.sol) runtime size 16716 bytes, headroom 7860 bytes (min 1024)` | 0 |
| min raised to 99999 | `::error::... headroom 7860 is below the 99999 byte minimum (or not a number)` | 1 |
| path in the jq select changed to a file that does not exist | `::error::expected exactly one ArtCoinsHookV2 (src/v2/hooks/ArtCoinsHookV2.sol) entry in the size json, got: none` | 1 |

the json holds exactly one key starting with `ArtCoinsHookV2` in this build, so the gate cannot match the legacy hook; a second match would fail the step by the count check.

## note: compile memory

a full compile of the tree in one solc process (viaIR, 140 stale files) was killed by the container oom killer at about 13.9 GB resident, twice, after about 15 minutes. locally the cache was warmed by building in batches (`forge build <paths>`), after which a full `forge test` run compiles nothing. a github runner that builds `forge build --sizes` cold compiles the same set in one process; if ci runs out of memory there, that is the cause, and the fix is a build split or a larger runner, not a code change.
