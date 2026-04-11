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
| Where is the public ops index? | `ops/README.md`; network-specific runbooks under `ops/local`, `ops/sepolia`, and `ops/optimism` are secondary references. |

## Build And Test

```bash
forge build
forge test --match-contract VolumeDynamicFeeHookAdminTest
forge test --match-contract VolumeDynamicFeeHookClaimAccountingIntegrationTest
forge test --offline
```

## Owner Authority Summary

Use the current contract API as the source of truth.

| Area | Summary |
| --- | --- |
| Ownership transfer | Two-step flow: `proposeNewOwner(...)`, optional `cancelOwnerTransfer()`, then `acceptOwner()` by the pending owner. `acceptOwner()` also clears any pending `HookFee` change. |
| HookFee control | Owner can `scheduleHookFeeChange(...)`, optionally `cancelHookFeeChange()`, and later `executeHookFeeChange()` after the `48 hours` timelock. |
| Fee and model configuration | Owner can update controller/reset/dust settings live via `setControllerSettings(...)`, `setResetSettings(...)`, and `setDustSwapThreshold(...)`; `setModeFees(...)` and `setModel(...)` are paused-only writes. |
| Safety controls | Owner can `pause()` / `unpause()` and can run paused-only `emergencyReset(...)` to `MODE_FLOOR` or `MODE_CASH`. |
| Funds | Owner can `claimHookFees()` to the current `owner()`, plus `rescueToken(...)` for non-pool assets and `rescueETH(...)`. |

## HookFee Lifecycle

1. `hookFeePercent` scales a separate trader-facing `HookFee` from the currently active LP fee.
2. Owner changes use a distinct `48 hours` timelock; only one pending `HookFee` change can exist at a time.
3. `pause()` does not block swaps, but it does suspend new `HookFee` accrual while paused.
4. `claimHookFees()` always pays the full currently accrued balances to the current `owner()`.
5. `acceptOwner()` moves future claim destination to the new owner and clears any pending `HookFee` change.

## Trust Boundary Summary

| Boundary | Summary |
| --- | --- |
| Pool binding | The hook is bound to exactly one pool key: one `currency0` / `currency1` pair, one `tickSpacing`, and one hook address. |
| PoolManager dependency | Swap accounting, LP-fee updates, and HookFee claim settlement depend on the configured `PoolManager`. |
| Hook identity | Hook address mining and callback flag correctness matter: the deployed address must expose only `afterInitialize`, `afterSwap`, and `afterSwapReturnDelta`. |
| Privileged owner | `owner()` is a highly privileged role with authority over fee settings, pause state, emergency reset, claims, and rescue paths. |
| Governance model | LP-fee behavior and HookFee behavior are contract-owner controlled. They are not trustless governance-controlled. |

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

## Public Ops Docs

Use `ops/README.md` as the public index for local, Sepolia, and Optimism helper scripts.
Network-specific runbooks remain discoverable under `ops/local`, `ops/sepolia`, and `ops/optimism`, but they are secondary references rather than the main reader path from this README.

## License / Usage Notice

This repository is source-available for review only. No license is granted for use, modification, deployment, or redistribution without prior written permission.
See `LICENSE` for the full terms.
