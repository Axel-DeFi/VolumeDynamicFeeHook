# Uniswap v4 VolumeDynamicFeeHook

`VolumeDynamicFeeHook` is a single-pool Uniswap v4 hook that updates LP fees from stable-side volume telemetry and
charges a separate trader-facing `HookFee` through `afterSwap`.

## Project Entry Points

| Question | Answer |
| --- | --- |
| What is this project? | A Uniswap v4 hook with explicit `FLOOR`, `CASH`, and `EXTREME` LP-fee modes plus owner-claimed `HookFee` accounting. |
| Where is the main contract? | `src/VolumeDynamicFeeHook.sol` |
| How do I run checks? | `forge build`, then targeted `forge test --match-contract ...` or `forge test --match-path ...` |
| Where is the behavior spec? | `docs/SPEC.md` |
| Where is the deploy / ops flow? | `ops/README.md`, with network-specific runbooks under `ops/local`, `ops/sepolia`, and `ops/optimism` |

## Build And Test

```bash
forge build
forge test --match-contract VolumeDynamicFeeHookAdminTest
forge test --match-contract VolumeDynamicFeeHookClaimAccountingIntegrationTest
forge test --offline
```

## Owner Configuration Groups

Use the current contract API as the source of truth. Owner writes are split into explicit groups:

| Group | Read path | Write path | Effect |
| --- | --- | --- | --- |
| Explicit LP-fee triplet | `getModeFees()` | `setModeFees(...)` | Paused-only maintenance update. Preserves active mode and EMA, clears hold/streak counters, starts a fresh open period, and immediately syncs the LP fee if the active tier changed. |
| Controller transition settings | `getControllerSettings()` | `setControllerSettings(...)` | Live operational change. Updates entry/exit thresholds immediately, keeps EMA and streak counters, and clamps any active mode hold to the new mode-specific maximum if the old hold would now exceed it. |
| Reset settings | `getResetSettings()`, `idleResetSeconds()`, `lowVolumeReset()`, `lowVolumeResetPeriods()` | `setResetSettings(...)` | Live operational change. Updates idle-reset and low-volume-reset thresholds immediately without resetting controller runtime state. |
| Model settings | `periodSeconds()`, `emaPeriods()` | `setModel(...)` | Paused-only model change. Safe-resets the controller to `FLOOR`, zeroes EMA/counters, restarts the open period, and syncs LP fee if needed. |
| Telemetry dust filter | `dustSwapThreshold()` | `setDustSwapThreshold(...)` | Live operational change. Applies immediately and affects only volume telemetry, not swap execution or fee charging. |

## HookFee Lifecycle

1. `hookFeePercent` scales a separate trader-facing `HookFee` from the currently active LP fee.
2. Owner changes follow a distinct timelock flow:
   - `scheduleHookFeeChange(...)`
   - optional `cancelHookFeeChange()`
   - `executeHookFeeChange()` after `48 hours`
3. Only one pending `HookFee` change can exist at a time.
4. `pause()` does not block swaps, but it does suspend new `HookFee` accrual while paused.
5. `claimHookFees()` always pays the full currently accrued balances to the current `owner()`.
6. `acceptOwner()` moves future claim destination to the new owner and clears any pending `HookFee` change.

## EMA Ratio Thresholds

The controller compares the closed-period volume with EMA using:

```text
ratioPct = (periodVolume * 100) / emaVolume
```

`emaVolume` is the unscaled EMA notionally expressed in the same internal 6-decimal USD unit as `periodVolume`.

| Setting | Example inputs | Ratio | Meaning |
| --- | --- | --- | --- |
| `enterCashEmaRatioPct = 190` | `emaVolume = $1,000`, `periodVolume = $2,000` | `200%` | The ratio side of `FLOOR -> CASH` passes because `200 >= 190`. `enterCashMinVolume` must also pass. |
| `enterExtremeEmaRatioPct = 410` | `emaVolume = $2,000`, `periodVolume = $8,400` | `420%` | Counts as a strong `CASH -> EXTREME` close because `420 >= 410`. `enterExtremeMinVolume` must also pass, and the confirm streak still applies. |
| `exitExtremeEmaRatioPct = 120` | `emaVolume = $3,000`, `periodVolume = $3,300` | `110%` | Counts as a weak `EXTREME` close because `110 <= 120`, so it can advance the `EXTREME -> CASH` down-streak. |
| `exitCashEmaRatioPct = 120` | `emaVolume = $2,500`, `periodVolume = $2,250` | `90%` | Counts as a weak `CASH` close because `90 <= 120`, so it can advance the `CASH -> FLOOR` down-streak. |

Volume gates and confirm counters still apply. The ratio thresholds are only one part of the transition rule set.

## Deploy And Operate

```bash
ops/local/scripts/bootstrap.sh

ops/sepolia/scripts/preflight.sh
ops/sepolia/scripts/ensure-hook.sh
ops/sepolia/scripts/ensure-pool.sh
ops/sepolia/scripts/ensure-liquidity.sh

ops/optimism/scripts/preflight.sh
ops/optimism/scripts/ensure-hook.sh
ops/optimism/scripts/ensure-pool.sh
ops/optimism/scripts/ensure-liquidity.sh
```

For operational details, use:
- `ops/README.md`
- `ops/local/RUNBOOK.md`
- `ops/sepolia/RUNBOOK.md`
- `ops/optimism/RUNBOOK.md`

## License / Usage Notice

This repository is source-available for review only. No license is granted for use, modification, deployment, or redistribution without prior written permission.
See `LICENSE` for the full terms.
