# VolumeDynamicFeeHook

A Uniswap v4 hook that dynamically adjusts LP fees based on real-time trading volume. The hook tracks stable-side notional volume via an EMA controller and automatically transitions between three fee regimes: Floor, Cash, and Extreme - to optimize LP returns across varying market conditions.

A separate **HookFee** -- a trader-facing charge proportional to the active LP fee -- provides protocol revenue with a 48-hour timelock on any parameter changes.

## Key Properties

- **Single-pool binding** -- one hook instance manages exactly one currency pair
- **Three fee modes** -- Floor (low activity), Cash (normal), Extreme (high volume) with configurable thresholds and confirm streaks
- **Volume-driven transitions** -- EMA-based controller with minimum volume gates and ratio thresholds
- **HookFee** -- separate protocol fee derived from LP fee, capped at 10%, with 48h timelock
- **Owner-controlled** -- two-step ownership transfer; pause, emergency reset, and rescue capabilities
- **Hook callbacks** -- `afterInitialize`, `afterSwap`, `afterSwapReturnDelta` only

## Deployment

| Network | Contract | Address |
|---------|----------|---------|
| Optimism | VolumeDynamicFeeHook | [`0x2C3254Da64956F495356A482D51E7311347f5044`](https://optimistic.etherscan.io/address/0x2C3254Da64956F495356A482D51E7311347f5044) |
| Optimism | Pool (ETH / USDC) | [`0x226d6297...31fa6974c`](https://app.uniswap.org/explore/pools/optimism/0x226d6297e0a25f5c1441a73922f166f16be6963b7d86dfbb97faa9e31fa6974c) |

## Documentation

| Document | Description |
|----------|-------------|
| [Product Concept (EN)](docs/concept-v2.4.0-en.pdf) | Dynamic fee mechanism, regimes, parameters, audit summary |
| [Product Concept (RU)](docs/concept-v2.4.0-ru.pdf) | Механизм динамической комиссии, режимы, параметры, аудит |
| [Security Audit (EN)](docs/audit-v2.4.0-en.pdf) | Full deep audit -- 15 sections, 5 informational findings |
| [Security Audit (RU)](docs/audit-v2.4.0-ru.pdf) | Полный глубокий аудит -- 15 разделов, 5 информационных наблюдений |
| [Technical Specification](docs/SPEC.md) | State machine, fee regimes, controller parameters, invariants |

## Security

Full deep security audit completed with **no confirmed vulnerabilities**:

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 0 |
| Low | 0 |
| Informational | 5 |

See the audit reports above for full details.

## License

This repository is source-available for review only. No license is granted for use, modification, deployment, or redistribution without prior written permission. See [LICENSE](LICENSE) for full terms.
