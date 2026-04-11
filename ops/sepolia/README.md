# Sepolia Ops

`ops/sepolia` exposes public rehearsal helpers for the shared live-ops stack.
It keeps the same read-only versus broadcast-capable phase split as local, without serving as a full operator handbook.

## Read-only phases

- `ops/sepolia/scripts/preflight.sh`
- `ops/sepolia/scripts/inspect.sh`

## Broadcast-capable phases

- `ops/sepolia/scripts/ensure-hook.sh`
- `ops/sepolia/scripts/ensure-pool.sh`
- `ops/sepolia/scripts/ensure-liquidity.sh`
- `ops/sepolia/scripts/gas.sh`
- `ops/sepolia/scripts/smoke.sh`
- `ops/sepolia/scripts/full.sh`
- `ops/sepolia/scripts/rerun-safe.sh`
- `ops/sepolia/scripts/emergency.sh`

## Public artifacts

- `ops/sepolia/out/reports/*.json`
- `ops/sepolia/out/state/*.json`
- `ops/sepolia/out/logs/*.log`

## Notes

- Sepolia wrappers reuse shared validation logic from `ops/shared`.
- `preflight` and `inspect` are the public read-only gate before broadcast-capable phases.
- Detailed environment policy, budgets, monitoring, and incident handling are intentionally outside this public repo.
