# Public Ops Index

`ops/` contains public helper scripts and reference material for local validation, Sepolia rehearsal, and Optimism deployment support.
It is not a complete production operations handbook.

## High-level layers

- `ops/shared` — shared Foundry scripts, config schema, and reusable helpers.
- `ops/tests` — ops-oriented test harnesses.
- `ops/local` — deterministic local rehearsal and validation.
- `ops/sepolia` — public testnet rehearsal helpers.
- `ops/optimism` — deployment and validation helpers for Optimism.

## Phase boundary

- Read-only: `preflight`, `inspect`
- Broadcast-capable: `bootstrap`, `ensure-*`, `smoke`, `full`, `rerun-safe`, `emergency`

## Public docs

- Local: `ops/local/README.md`, `ops/local/RUNBOOK.md`, `ops/local/SCENARIOS.md`, `ops/local/ACCEPTANCE.md`
- Sepolia: `ops/sepolia/README.md`, `ops/sepolia/RUNBOOK.md`, `ops/sepolia/SCENARIOS.md`, `ops/sepolia/ACCEPTANCE.md`
- Optimism: `ops/optimism/README.md`, `ops/optimism/RUNBOOK.md`, `ops/optimism/SCENARIOS.md`, `ops/optimism/ACCEPTANCE.md`
- Shared schema: `ops/shared/config/schema.md`, `ops/shared/config/scenario.schema.md`

Private production approvals, monitoring, response playbooks, and key-management procedures should live in a separate internal ops project.
