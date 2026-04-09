# Optimism Runbook

## Read-only gate

```bash
ops/optimism/scripts/preflight.sh
ops/optimism/scripts/inspect.sh
```

Stop if preflight fails.
`smoke/full/rerun-safe/emergency` wrappers enforce this gate by default.

## Ensure state

```bash
ops/optimism/scripts/ensure-hook.sh
ops/optimism/scripts/ensure-pool.sh
ops/optimism/scripts/ensure-liquidity.sh
```

All three phases use the shared canonical live-ops stack:
- canonical CREATE2 hook identity derived from `ops/optimism/config/deploy.env`,
- exact callback surface validation,
- exact PoolManager binding,
- full runtime config validation,
- zero pending owner / pending HookFee change.

## Validation suite

```bash
ops/optimism/scripts/smoke.sh
ops/optimism/scripts/full.sh
ops/optimism/scripts/rerun-safe.sh
ops/optimism/scripts/emergency.sh
```

## Owner flows

### Ownership transfer

1. Current owner calls `proposeNewOwner(newOwner)`.
2. Current owner may cancel with `cancelOwnerTransfer()`.
3. Pending owner finalizes with `acceptOwner()`.

`acceptOwner()` also clears any pending `HookFee` change.

### HookFee lifecycle

1. Schedule via `scheduleHookFeeChange(newPercent)`.
2. Optionally cancel via `cancelHookFeeChange()`.
3. Execute via `executeHookFeeChange()` after `48 hours`.

`HookFee` accrues only while the hook is not paused.
`claimHookFees()` always pays the full accrued balance to the current `owner()`.

## Change classes

| Change class | Function(s) | Requires pause | Runtime effect |
| --- | --- | --- | --- |
| Model change | `setModel(...)` | Yes | Safe reset to `FLOOR`, zero EMA/counters, fresh open period, LP-fee sync if the active tier changes. |
| Paused LP-fee maintenance | `setModeFees(...)` | Yes | Preserves active mode and EMA, clears hold/streak counters, fresh open period, immediate LP-fee sync if the active tier changes. |
| Live controller tuning | `setControllerSettings(...)` | No | Updates transition thresholds immediately without resetting EMA or controller counters. |
| Live reset tuning | `setResetSettings(...)` | No | Updates `idleResetSeconds`, `lowVolumeReset`, and `lowVolumeResetPeriods` immediately without resetting controller runtime state. |
| Live telemetry dust tuning | `setDustSwapThreshold(...)` | No | Applies immediately. Filters telemetry only and never schedules activation for a later period boundary. |
| Timelocked HookFee update | `scheduleHookFeeChange(...)`, `cancelHookFeeChange()`, `executeHookFeeChange()` | No | Separate 48-hour timelock flow. Not part of model/controller/reset writes. |

## Pause and emergency semantics

- `pause()` / `unpause()` freeze and resume controller evolution.
- Swaps continue while paused.
- New `HookFee` accrual is suspended while paused.
- `emergencyReset(uint8 targetMode)` is paused-only and accepts `MODE_FLOOR` or `MODE_CASH`.
- Monitoring must consume `EmergencyResetToFloorApplied` / `EmergencyResetToCashApplied`, not only `FeeUpdated`.

## Operational requirements

- Production owner must be multisig with cold/hardware custody.
- Fill `ops/optimism/config/deploy.env` for constructor and bootstrap values, including `INIT_PRICE_USD` before `ensure-pool`.
- Leave `ops/optimism/config/defaults.env` for runtime wiring, budgets, and optional runtime overrides.
- Live budgets default to zero; set budget env values explicitly before `ensure-liquidity` or swap-validation phases.
- Liquidity/swap helper drivers are reused only if their runtime codehash and bound `manager()` match the expected
  canonical helper for the configured `POOL_MANAGER`; otherwise wrappers reprovision them.
- For native-asset pools, owner must remain compatible with native payout from the PoolManager claim path.
- Hold guidance remains `holdCashPeriods >= 2`, `holdExtremePeriods >= 2` unless an explicit override is justified.
- `ops/optimism/config/deploy.env` is the primary file to fill before deployment; `defaults.env` may stay minimal and
  only needs explicit overrides when runtime/admin expectations drift from that snapshot.
- The shared shell loader sources `deploy.env` after scenario overlays and root `.env`, so stray `DEPLOY_*` values in
  overlays cannot silently override the canonical snapshot.
- `DEPLOY_*` entries in `deploy.env` must be literal values; shell interpolation is rejected. Set the exact production
  multisig directly in `DEPLOY_OWNER` before first live deployment.

## Monitoring minimums

- Track `PeriodClosed`, `ControllerTransitionTrace`, and `FeeUpdated` for controller behavior.
- Track owner and HookFee lifecycle events:
  `OwnerTransferStarted`, `OwnerTransferCancelled`, `OwnerTransferAccepted`, `OwnerUpdated`,
  `HookFeeChangeScheduled`, `HookFeeChangeCancelled`, `HookFeeChanged`, `HookFeesClaimed`.
- Track config and safety events:
  `ModeFeesUpdated`, `ControllerSettingsUpdated`, `ModelUpdated`, `ResetSettingsUpdated`,
  `DustSwapThresholdChanged`, `Paused`, `Unpaused`, `EmergencyResetToFloorApplied`,
  `EmergencyResetToCashApplied`.
