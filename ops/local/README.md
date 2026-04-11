# Local Ops (Anvil)

`ops/local` contains public local rehearsal helpers built from thin shell wrappers and Foundry scripts.
It is intended for deterministic validation, not as a production operator handbook.

## Read-only phases

- `ops/local/scripts/preflight.sh`
- `ops/local/scripts/inspect.sh`

## Broadcast-capable phases

- `ops/local/scripts/bootstrap.sh`
- `ops/local/scripts/ensure-hook.sh`
- `ops/local/scripts/ensure-pool.sh`
- `ops/local/scripts/ensure-liquidity.sh`
- `ops/local/scripts/gas.sh`
- `ops/local/scripts/smoke.sh`
- `ops/local/scripts/full.sh`
- `ops/local/scripts/rerun-safe.sh`
- `ops/local/scripts/emergency.sh`

## Process control

- `ops/local/scripts/anvil-up.sh`
- `ops/local/scripts/anvil-down.sh`
- `ops/local/scripts/reset-state.sh`

## Public artifacts

- `ops/local/out/reports/*.json`
- `ops/local/out/state/*.json`
- `ops/local/out/logs/*.log`

## Notes

- Local wrappers mirror the public phase names used by live-network wrappers.
- Constructor/runtime config and generated state stay under `ops/local/config` and `ops/local/out`.
- Detailed monitoring policy, incident handling, and other private operator procedures are intentionally outside this public repo.
