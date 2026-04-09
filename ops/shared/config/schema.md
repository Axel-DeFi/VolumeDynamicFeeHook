# Ops Config Schema

File-backed live config is loaded in this order:
- `defaults.env`
- scenario overlay
- repository root `.env`
- `deploy.env`

In normal day-to-day setup, edit `deploy.env`.
Keep `defaults.env` for runtime wiring, budgets, and explicit post-deploy runtime overrides.
Do not persist live `HOOK_ADDRESS` or `POOL_ID` bindings in tracked `defaults.env`.

After file loading, wrapper scripts may hydrate runtime-only addresses from state JSON:
- `POOL_MANAGER`, `HOOK_ADDRESS`, `VOLATILE`, `STABLE` from `ops/<network>/out/state/*.addresses.json`
- `SWAP_DRIVER`, `LIQUIDITY_DRIVER` from `ops/<network>/out/state/*.drivers.json`

Canonical hook identity is derived only from `DEPLOY_*` keys, so state hydration must not change deployment
snapshot inputs.

## Required keys

- `OPS_RUNTIME` = `local|live`
- `CHAIN_ID_EXPECTED`
- `RPC_URL` (required for real RPC execution)
- `PRIVATE_KEY` or `DEPLOYER`

Binding keys may come from either the runtime key or the frozen deployment snapshot:
- `POOL_MANAGER` or `DEPLOY_POOL_MANAGER`
- `VOLATILE` or `DEPLOY_VOLATILE`
- `STABLE` or `DEPLOY_STABLE`
- `TICK_SPACING` or `DEPLOY_TICK_SPACING`

Stable-token decimals resolution:
- `STABLE_DECIMALS` remains available as an explicit runtime override when a local token is not deployed yet.
- Otherwise the loader resolves stable decimals onchain from `STABLE` / `DEPLOY_STABLE` via `decimals()`.

## Hook / pool binding

- `HOOK_ADDRESS` remains an optional runtime override.
  - tracked configs should not pin it; shared live wrappers may hydrate it from `ops/<network>/out/state/*.addresses.json`
  - when provided for deploy/ensure/preflight validation, it must be the canonical CREATE2 hook address for the
    frozen deployment snapshot loaded from `ops/<network>/config/deploy.env`
- `POOL_ID` remains an optional runtime override for explicit validation and diagnostics.
  - tracked configs should not pin it; when provided, it is validated against the canonical hook pool key

## Pool initialization

- `INIT_PRICE_USD` — initial pool price in USD stored in `deploy.env`. Example: `2500`.
- `EnsurePoolLive` derives `sqrtPriceX96` directly from `INIT_PRICE_USD` and token decimals.

## Explicit mode fees

- Runtime fee/controller keys may be omitted from `defaults.env`. If omitted, the loader inherits the corresponding
  `DEPLOY_*` value. Set the runtime key only when post-deploy admin changes are expected onchain.
- `FLOOR_FEE_PERCENT` — LP fee for the `FLOOR` mode, as a percent. Example: `0.04`.
- `CASH_FEE_PERCENT` — LP fee for the `CASH` mode, as a percent. Example: `0.25`.
- `EXTREME_FEE_PERCENT` — LP fee for the `EXTREME` mode, as a percent. Example: `0.9`.

## Timing / controller

Human-readable units for controller keys:
- `*_EMA_RATIO_PERCENT` keys use integer percent values for the period-volume / EMA ratio. Example: `125` means `125%` of EMA.
- all `*VOLUME` keys use dollars in the internal six-decimal scale. Example: `1000000000` means `$1,000`.
- the six-decimal dollar unit is documented here and does not appear in key names.

- `PERIOD_SECONDS` — close period length in seconds. Example: `60`.
- `EMA_PERIODS` — EMA denominator in periods. Example: `12`.
- `IDLE_RESET_SECONDS` — inactivity timeout that forces a fresh open period. Example: `600`.
- `HOOK_FEE_PERCENT` — additional trader fee as a percent of the active LP fee. Example: `10`.
- `ENTER_CASH_MIN_VOLUME` — minimum period volume required before `FLOOR -> CASH` is allowed. Example: `1000000000`.
- `ENTER_CASH_EMA_RATIO_PERCENT` — minimum period-volume / EMA ratio for `FLOOR -> CASH`, in percent. Example: `190`.
- `HOLD_CASH_PERIODS` — configured cash hold length `N` (`N - 1` fully protected periods). Example: `4`.
- `ENTER_EXTREME_MIN_VOLUME` — minimum period volume required before `CASH -> EXTREME` is allowed. Example: `4000000000`.
- `ENTER_EXTREME_EMA_RATIO_PERCENT` — minimum period-volume / EMA ratio for `CASH -> EXTREME`, in percent. Example: `410`.
- `ENTER_EXTREME_CONFIRM_PERIODS` — consecutive qualifying closes required before entering `EXTREME`. Example: `2`.
- `HOLD_EXTREME_PERIODS` — configured hold length after entering `EXTREME`. Example: `4`.
- `EXIT_EXTREME_EMA_RATIO_PERCENT` — maximum period-volume / EMA ratio for `EXTREME -> CASH`, in percent. Example: `120`.
- `EXIT_EXTREME_CONFIRM_PERIODS` — consecutive qualifying closes required before leaving `EXTREME`. Example: `2`.
- `EXIT_CASH_EMA_RATIO_PERCENT` — maximum period-volume / EMA ratio for `CASH -> FLOOR`, in percent. Example: `120`.
- `EXIT_CASH_CONFIRM_PERIODS` — consecutive qualifying closes required before leaving `CASH`. Example: `3`.
- `LOW_VOLUME_RESET` — emergency floor threshold checked against period volume. Example: `600000000`.
- `LOW_VOLUME_RESET_PERIODS` — consecutive closes below `LOW_VOLUME_RESET` required for emergency reset. Example: `3`.

## Frozen deployment snapshot

These keys live in `ops/<network>/config/deploy.env` for live profiles. They define the constructor snapshot used to
derive the canonical CREATE2 hook address and must not be edited after the canonical hook is deployed. The ops shell
loaders source `deploy.env` after scenario overlays and root `.env`, so `DEPLOY_*` values win if duplicates exist.
`DEPLOY_*` entries must be literal values in `deploy.env`; shell interpolation like `${DEFAULT_OWNER}` is rejected so
the snapshot cannot drift with outer environment changes.

- `DEPLOY_POOL_MANAGER`
- `DEPLOY_VOLATILE`
- `DEPLOY_STABLE`
- `DEPLOY_TICK_SPACING`
- `DEPLOY_OWNER`
- `DEPLOY_FLOOR_FEE_PERCENT` — same meaning as `FLOOR_FEE_PERCENT`. Example: `0.04`.
- `DEPLOY_CASH_FEE_PERCENT` — same meaning as `CASH_FEE_PERCENT`. Example: `0.25`.
- `DEPLOY_EXTREME_FEE_PERCENT` — same meaning as `EXTREME_FEE_PERCENT`. Example: `0.9`.
- `DEPLOY_PERIOD_SECONDS`
- `DEPLOY_EMA_PERIODS`
- `DEPLOY_IDLE_RESET_SECONDS`
- `DEPLOY_HOOK_FEE_PERCENT`
- `DEPLOY_ENTER_CASH_MIN_VOLUME` — same meaning as `ENTER_CASH_MIN_VOLUME`. Example: `1000000000`.
- `DEPLOY_ENTER_CASH_EMA_RATIO_PERCENT` — same meaning as `ENTER_CASH_EMA_RATIO_PERCENT`. Example: `190`.
- `DEPLOY_HOLD_CASH_PERIODS`
- `DEPLOY_ENTER_EXTREME_MIN_VOLUME` — same meaning as `ENTER_EXTREME_MIN_VOLUME`. Example: `4000000000`.
- `DEPLOY_ENTER_EXTREME_EMA_RATIO_PERCENT` — same meaning as `ENTER_EXTREME_EMA_RATIO_PERCENT`. Example: `410`.
- `DEPLOY_ENTER_EXTREME_CONFIRM_PERIODS` — same meaning as `ENTER_EXTREME_CONFIRM_PERIODS`. Example: `2`.
- `DEPLOY_HOLD_EXTREME_PERIODS`
- `DEPLOY_EXIT_EXTREME_EMA_RATIO_PERCENT` — same meaning as `EXIT_EXTREME_EMA_RATIO_PERCENT`. Example: `120`.
- `DEPLOY_EXIT_EXTREME_CONFIRM_PERIODS` — same meaning as `EXIT_EXTREME_CONFIRM_PERIODS`. Example: `2`.
- `DEPLOY_EXIT_CASH_EMA_RATIO_PERCENT` — same meaning as `EXIT_CASH_EMA_RATIO_PERCENT`. Example: `120`.
- `DEPLOY_EXIT_CASH_CONFIRM_PERIODS` — same meaning as `EXIT_CASH_CONFIRM_PERIODS`. Example: `3`.
- `DEPLOY_LOW_VOLUME_RESET` — same meaning as `LOW_VOLUME_RESET`. Example: `600000000`.
- `DEPLOY_LOW_VOLUME_RESET_PERIODS`
- `INIT_PRICE_USD` — pool bootstrap price consumed by `ensure-pool`. Example: `2500`.

For all profiles, constructor-aligned runtime keys are optional and fall back to the corresponding `DEPLOY_*` values.
Use the runtime key only when validation should expect post-deploy drift from the frozen snapshot.

## Optional runtime overrides

- `DUST_SWAP_THRESHOLD` — telemetry dust filter in the internal six-decimal dollar scale when a non-default runtime threshold is required.
  When omitted, the loader uses `4_000_000`. Example: `4000000` for `$4`.

Controller constraint notes:
- `LOW_VOLUME_RESET` must be strictly greater than zero.
- `LOW_VOLUME_RESET` must be strictly lower than `ENTER_CASH_MIN_VOLUME`.
- `ENTER_CASH_EMA_RATIO_PERCENT` must be less than or equal to `ENTER_EXTREME_EMA_RATIO_PERCENT`.
- `EXIT_EXTREME_EMA_RATIO_PERCENT` must be less than or equal to `EXIT_CASH_EMA_RATIO_PERCENT`.
- `HOLD_CASH_PERIODS` and `HOLD_EXTREME_PERIODS` block only the ordinary down path.
- The emergency path continues counting during hold.
- The earliest ordinary `cash -> floor` descent is `holdCashPeriods + exitCashConfirmPeriods - 1`.
- The earliest ordinary `extreme -> cash` descent is `holdExtremePeriods + exitExtremeConfirmPeriods - 1`.
- The earliest emergency descent is `lowVolumeResetPeriods`.
- Hold semantics are `N -> N - 1` fully protected periods; production guidance is
  `HOLD_CASH_PERIODS >= 2` and `HOLD_EXTREME_PERIODS >= 2` (recommended `3..4`).

## Budget safety keys

- `BUDGET_MIN_ETH_WEI`
- `BUDGET_MIN_STABLE_RAW`
- `BUDGET_MIN_VOLATILE_RAW`
- `BUDGET_LIQ_STABLE_RAW`
- `BUDGET_LIQ_VOLATILE_RAW`
- `BUDGET_SWAP_STABLE_RAW`
- `BUDGET_SWAP_VOLATILE_RAW`
- `BUDGET_SAFETY_BUFFER_ETH_WEI`

## Optional execution knobs

- `OPS_BROADCAST` (`0|1`)
- `OPS_FORCE_SIMULATION` (`0|1`)
- `OPS_NETWORK` (normally set by wrappers; `sepolia` or `optimism` for shared live paths)
- `ALLOW_WEAK_HOLD_PERIODS` (`true|false`, default `false`; explicit override for non-local weak hold configs)
- `SMOKE_SWAP_STABLE_RAW`
- `FULL_SWAP_STABLE_RAW`
- `FULL_SWAP_ITERATIONS`
- `RERUN_SWAP_STABLE_RAW`
- `SEED_STABLE_RAW`
- `SEED_VOLATILE_RAW`
- `PERIODS_TO_WARP`
- `WARP_CLOSE_PERIOD`
- `SWAP_DRIVER` (external helper contract for live swaps; reused only if runtime codehash and bound `manager()`
  match the expected canonical helper for the current `POOL_MANAGER`, otherwise auto-reprovisioned)
- `LIQUIDITY_DRIVER` (external helper contract for live liquidity actions; same validation/reprovision rule as
  `SWAP_DRIVER`)
