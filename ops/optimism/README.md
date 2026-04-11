# Optimism Ops

`ops/optimism` exposes the public-facing wrapper layer for Optimism deployment and validation helpers.
It uses the same shared live-ops surface as Sepolia, without serving as a full production operator handbook.

## Read-only phases

- `ops/optimism/scripts/preflight.sh`
- `ops/optimism/scripts/inspect.sh`

## Broadcast-capable phases

- `ops/optimism/scripts/ensure-hook.sh`
- `ops/optimism/scripts/ensure-pool.sh`
- `ops/optimism/scripts/ensure-liquidity.sh`
- `ops/optimism/scripts/smoke.sh`
- `ops/optimism/scripts/full.sh`
- `ops/optimism/scripts/rerun-safe.sh`
- `ops/optimism/scripts/emergency.sh`

## Notes

- Shell wrappers and Foundry scripts are shared with Sepolia under `ops/shared`.
- `preflight` and `inspect` are the public read-only gate before broadcast-capable phases.
- Private production approvals, monitoring, and incident procedures are intentionally outside this public repo.
