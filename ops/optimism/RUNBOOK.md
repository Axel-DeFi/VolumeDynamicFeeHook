# Optimism Runbook

This runbook is a public high-level reference for Optimism deployment and validation helpers.
Contract behavior belongs in `README.md` and `docs/SPEC.md`; private production operations policy is intentionally out of scope here.

## Read-only gate

```bash
ops/optimism/scripts/preflight.sh
ops/optimism/scripts/inspect.sh
```

`preflight` and `inspect` are read-only phases.

## Broadcast-capable ensure phases

```bash
ops/optimism/scripts/ensure-hook.sh
ops/optimism/scripts/ensure-pool.sh
ops/optimism/scripts/ensure-liquidity.sh
```

These phases can broadcast transactions.

## Validation suite

```bash
ops/optimism/scripts/smoke.sh
ops/optimism/scripts/full.sh
ops/optimism/scripts/rerun-safe.sh
ops/optimism/scripts/emergency.sh
```

## Public-safe notes

- Read-only phases are suitable for inspection; `ensure-*`, `smoke`, `full`, `rerun-safe`, and `emergency` are broadcast-capable.
- Shared validation covers canonical hook identity, callback flags, and the bound pool assumptions before live actions.
- Detailed environment management, approvals, monitoring, and incident response belong in a separate internal ops project.
