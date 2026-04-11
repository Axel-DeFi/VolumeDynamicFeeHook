# Local Runbook

This runbook is a public high-level reference for local rehearsal only.
Contract behavior and owner semantics are specified in `README.md` and `docs/SPEC.md`.
Private production procedures are intentionally out of scope here.

## Start / stop

```bash
ops/local/scripts/anvil-up.sh
ops/local/scripts/anvil-down.sh
```

## Read-only phases

```bash
ops/local/scripts/preflight.sh
ops/local/scripts/inspect.sh
```

## Broadcast-capable phases

```bash
ops/local/scripts/bootstrap.sh
ops/local/scripts/ensure-hook.sh
ops/local/scripts/ensure-pool.sh
ops/local/scripts/ensure-liquidity.sh
ops/local/scripts/gas.sh
ops/local/scripts/smoke.sh
ops/local/scripts/full.sh
ops/local/scripts/rerun-safe.sh
ops/local/scripts/emergency.sh
```

## Notes

- Public config and generated artifacts live under `ops/local/config` and `ops/local/out`.
- Read-only phases are safe for inspection; the broadcast-capable phases can mutate local state.
- Detailed monitoring policy, incident response, and live operator discipline belong in a separate internal ops project.
