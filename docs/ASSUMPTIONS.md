# Assumptions

This document defines trust assumptions, external dependencies, and operational constraints
that are outside the contract specification (`SPEC.md`) but are load-bearing for the overall
security posture. The security audit skill references this document as a source of truth
for facts that the contract code alone cannot express.

If there is a conflict between this document and observed contract behavior, the contract
behavior is authoritative for contract-level properties. This document is authoritative
for deployment constraints and operational assumptions.

## Token assumptions

- The hook assumes standard ERC20 behavior for both pool tokens.
- Tokens with fee-on-transfer, rebasing mechanics, or non-standard `balanceOf` semantics
  are not supported and must not be used in pools managed by this hook.
- The token pair is fixed at pool creation time and cannot be changed.

## External dependencies

- **Uniswap v4 PoolManager**: the hook trusts `PoolManager` callback integrity, delta
  accounting, and ERC6909 claim semantics. `PoolManager` is an audited Uniswap v4
  protocol component. Its correctness is an external assumption, not verified by this hook.
- **block.timestamp**: period boundaries and idle-reset logic rely on `block.timestamp`.
  On L2 networks the sequencer controls timestamp progression; deviations of seconds
  are irrelevant given that periods are measured in hours or days.

## Operational assumptions

- **Owner key**: the contract enforces two-step ownership transfer and parameter bounds
  but does not enforce the type of owner account. In production deployments the owner
  is a multisig wallet. Key management procedures, signer policies, and incident response
  are outside the contract scope.
- **Parameter calibration**: the contract validates individual parameter bounds and
  cross-parameter consistency at set time, but economic optimality of the chosen values
  is the operator's responsibility.

## Network assumptions

- The hook is a multi-network solution. Each deployment targets a specific EVM-compatible
  network (L1 or L2) with its own pool, token pair, and operator configuration.
- Network-specific deployment parameters are stored in per-network configuration under `ops/`.
- The contract itself is network-agnostic; no chain ID or network-specific logic is hardcoded.
