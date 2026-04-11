# Sepolia Runbook

This runbook is a public high-level reference for Sepolia rehearsal.
Contract semantics remain in `README.md` and `docs/SPEC.md`; private live-operations policy is intentionally out of scope here.

## Read-only gate

```bash
ops/sepolia/scripts/preflight.sh
ops/sepolia/scripts/inspect.sh
```

`preflight` and `inspect` are read-only phases.

## Broadcast-capable ensure phases

```bash
ops/sepolia/scripts/ensure-hook.sh
ops/sepolia/scripts/ensure-pool.sh
ops/sepolia/scripts/ensure-liquidity.sh
```

These phases can broadcast transactions.

## Validation suite

```bash
ops/sepolia/scripts/gas.sh
ops/sepolia/scripts/smoke.sh
ops/sepolia/scripts/full.sh
ops/sepolia/scripts/rerun-safe.sh
ops/sepolia/scripts/emergency.sh
```

## Public-safe notes

- Read-only phases are suitable for inspection; `ensure-*`, `gas`, `smoke`, `full`, `rerun-safe`, and `emergency` are broadcast-capable.
- Shared validation covers canonical hook identity, callback flags, and bound pool assumptions before live actions.
- Detailed environment management, budgets, monitoring, and incident response belong in a separate internal ops project.
