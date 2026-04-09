# Local Runbook

## Start / stop

```bash
ops/local/scripts/anvil-up.sh
ops/local/scripts/anvil-down.sh
```

### Proxy-stable environment (Foundry on macOS)

If Foundry panics on system proxy discovery, pin proxy vars before running scripts:

```bash
export NO_PROXY='127.0.0.1,localhost'
export no_proxy='127.0.0.1,localhost'
export HTTP_PROXY='http://127.0.0.1:9'
export HTTPS_PROXY='http://127.0.0.1:9'
export ALL_PROXY='http://127.0.0.1:9'
```

## Bootstrap and checks

```bash
ops/local/scripts/preflight.sh
ops/local/scripts/bootstrap.sh
ops/local/scripts/inspect.sh
ops/local/scripts/smoke.sh
ops/local/scripts/full.sh
ops/local/scripts/rerun-safe.sh
ops/local/scripts/emergency.sh
```

Populate constructor and bootstrap values in `ops/local/config/deploy.env`.
Leave `ops/local/config/defaults.env` for runtime wiring, budgets, and optional runtime overrides.

## Gas evidence reproduction

```bash
forge test --offline --gas-report --match-contract VolumeDynamicFeeHookAdminTest > ops/local/out/reports/gas.admin.report.txt
ops/local/scripts/gas.sh
```

Artifacts:
- `ops/local/out/reports/gas.admin.report.txt`
- `ops/local/out/reports/gas.samples.local.json`
- `ops/local/out/reports/gas.local.json`
- `ops/local/out/reports/gas.local.md`

## Admin operation model

### Ownership transfer (2-step)

1. Current owner calls `proposeNewOwner(newOwner)`.
2. Current owner may cancel via `cancelOwnerTransfer()`.
3. Pending owner finalizes with `acceptOwner()`.

`acceptOwner()` also clears any pending `HookFee` change.

### HookFee timelock (48h)

1. `scheduleHookFeeChange(newPercent)`
2. optional `cancelHookFeeChange()`
3. after delay: `executeHookFeeChange()`

Timelock visibility is intentional. The main exposed effect is HookFee timing; LP fee ownership/accrual is unchanged.

### HookFee claim settlement

- Use `claimHookFees()` as owner to claim full accrued balance.
- Payout always goes to current `owner()`; no recipient override.
- Payout path is PoolManager accounting withdrawal: `unlock` -> `burn` -> `take`.
- Oversized payouts are chunked automatically so each `burn` / `take` fits PoolManager `int128` accounting bounds.
- If pool includes native currency, recipient must be compatible with native payout from PoolManager sender context in the claim path.
- Local preflight/deploy flow validates this compatibility before deployment/ensure.
- If ownership changes later in a native-asset pool, keep this compatibility invariant.

## Pause vs emergency reset

### `pause()` / `unpause()`

- Freeze/resume controller evolution.
- Preserve fee mode and EMA.
- Clear only open period volume and restart period boundary.
- Do not disable swaps.
- Suspend HookFee accrual while paused.

### Paused maintenance updates

- `setModeFees(...)` is paused-only, preserves active mode + EMA, clears hold/streak counters, starts a fresh open period, and syncs LP fee if the active mode fee changed.
- `setControllerSettings(...)` updates transition thresholds immediately without resetting EMA or counters.
- `setModel(...)` is paused-only and always performs a safe reset to `FLOOR` with zero EMA/counters and a fresh open period.
- `setResetSettings(...)` updates `idleResetSeconds`, `lowVolumeReset`, and `lowVolumeResetPeriods` immediately without resetting runtime state.

### Emergency resets (paused-only)

- `emergencyReset(uint8 targetMode)` — `targetMode` must be `MODE_FLOOR` (0) or `MODE_CASH` (1).

Clears EMA/streaks/hold counters and restarts period. Cash is the default emergency target unless floor lockdown is explicitly required.
If target tier already equals current tier, reset still applies but no `FeeUpdated` event is emitted.
Monitoring must consume `EmergencyResetToFloorApplied` / `EmergencyResetToCashApplied` events.

## Dust threshold operations

`dustSwapThreshold` is telemetry-only filtering and never blocks swaps.
Range for updates is `1e6..10e6`; default is `$4 / 4e6` (selected from observed v1 telemetry).

Flow:
1. `setDustSwapThreshold(value)`
2. new threshold applies immediately.

Notes:
- No timelock for threshold updates (project decision).
- Recalibration target cadence: every 5 days from offchain analytics.
- Dust filtering is mitigation, not a formal proof against all fragmentation patterns on cheap L2.
- Overdue catch-up can close multiple periods in one swap; only the first close uses accumulated period volume and later closes use zero period volume.
- Multi-close downward sequences are accepted architectural/economic behavior in this scope and should be monitored as notable routing/yield events.

## Accepted governance risks

- Mitigation is operational: owner key controls + monitoring/alerting.
- Production owner must be multisig; local EOA owner is acceptable only for dev/test.
- Hot-wallet owner usage is unacceptable for production; use cold/hardware custody.
- Reuse of an existing hook in deploy/ensure/preflight is pinned to the canonical CREATE2 address derived from the
  frozen `ops/local/config/deploy.env` constructor snapshot; current runtime/admin
  expectations come from `ops/local/config/defaults.env` only when explicitly overridden, otherwise they inherit the
  frozen snapshot. Reuse also requires the exact minimal callback surface, exact PoolManager binding, current
  `dustSwapThreshold`, and zero pending owner / pending HookFee change.
- `deploy.env` is loaded after scenario overlays and root `.env`, so `DEPLOY_*` keys remain the winning constructor
  snapshot even when runtime env overlays are used.

Controller safety note:
- `lowVolumeReset` must remain strictly greater than zero.
- `lowVolumeReset` must remain strictly less than `enterCashMinVolume`.
- Hold semantics are `N -> N - 1`; production guidance is `holdCashPeriods >= 2`, `holdExtremePeriods >= 2` (recommended `3..4`).
- Non-local deploy/preflight paths block weak hold configs by default; explicit override: `ALLOW_WEAK_HOLD_PERIODS=1`.

## Monitoring minimums

- Track `PeriodClosed`, `ControllerTransitionTrace`, and `FeeUpdated` for controller behavior.
- Track owner and HookFee lifecycle events:
  `OwnerTransferStarted`, `OwnerTransferCancelled`, `OwnerTransferAccepted`, `OwnerUpdated`,
  `HookFeeChangeScheduled`, `HookFeeChangeCancelled`, `HookFeeChanged`, `HookFeesClaimed`.
- Track config and safety events:
  `ModeFeesUpdated`, `ControllerSettingsUpdated`, `ModelUpdated`, `ResetSettingsUpdated`,
  `DustSwapThresholdChanged`, `Paused`, `Unpaused`, `EmergencyResetToFloorApplied`,
  `EmergencyResetToCashApplied`.
- Treat wash-trading and fee-poisoning as residual economic risks in adversarial routing environments.
