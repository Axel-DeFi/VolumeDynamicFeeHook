# Period-close event emission optimization

Status: approved (design)
Date: 2026-04-30
Scope: `src/VolumeDynamicFeeHook.sol`, related unit tests, `docs/SPEC.md`

## Problem

On every period close inside `_afterSwap()` (and on the explicit idle-reset
path) the hook emits two events back-to-back:

- `PeriodClosed` (8 fields)
- `ControllerTransitionTrace` (13 fields)

Seven of the eight `PeriodClosed` fields are exactly duplicated inside
`ControllerTransitionTrace`. The duplication produces:

- Extra gas charged to whichever swapper closes the period (a marginal
  user-visible cost on period-boundary swaps; LPs receive less captured fee
  share through the fee tier path because the swap is paid by a single trader,
  but the broader system pays the cost in observable swap fees).
- Log noise: indexers and tools see two log entries per close where one
  carries the entire payload of the other plus extra diagnostic fields.

## Decisions

| # | Decision |
| - | - |
| 1 | Clean ABI break is acceptable. No backwards-compatibility shim. |
| 2 | Drop `PeriodClosed`. Keep the 13-field event as the single period-close event. |
| 3 | Rename the surviving event to `PeriodTrace`. Keep the helper named `_emitPeriodTrace`. |
| 4 | Update `docs/SPEC.md` to describe only current behavior (no "instead of", "replaces", "companion to", "previously"). |

## Architecture impact

### Event surface

| Before | After |
| - | - |
| `event PeriodClosed(uint24, uint8, uint24, uint8, uint64, uint96, uint64, uint8)` | removed |
| `event ControllerTransitionTrace(uint64, uint24, uint8, uint24, uint8, uint64, uint96, uint96, uint64, uint16, uint16, uint16, uint8)` | renamed to `event PeriodTrace(...)`; field set unchanged |

`FeeUpdated`, `Paused`, `Unpaused`, `IdleReset`, `HookFeesClaimed`, ownership
events and other unrelated events are not touched.

### Code structure

`_emitPeriodTrace(...)` keeps its 13-argument signature and its two call
sites (`src/VolumeDynamicFeeHook.sol:676`, `src/VolumeDynamicFeeHook.sol:748`)
unchanged. Its body reduces from two `emit` statements to a single
`emit PeriodTrace(...)`. The doc comment is rewritten to reference only
`PeriodTrace`.

### Gas and bytecode impact

- One `LOG1` instead of two on every period close.
- Approximate gas saving per close: ~2.8k gas (one fewer topic at 375 gas
  plus 256 bytes of LOG data at 8 gas per byte). This applies to whichever
  swap crosses a period boundary.
- Runtime bytecode shrinks slightly. EIP-170 was not at risk; the change is
  a side benefit, not a goal.

## File-level changes

### `src/VolumeDynamicFeeHook.sol`

1. Events section (around lines 212-245):
   - Delete the `event PeriodClosed(...)` declaration and its NatSpec.
   - Rename `event ControllerTransitionTrace(...)` to `event PeriodTrace(...)`.
     Field order and types remain identical.
   - Rewrite the NatSpec block above the event so it references `PeriodTrace`
     only and no longer mentions `PeriodClosed` as a precursor.
2. `_emitPeriodTrace` (around lines 1703-1744):
   - Keep the function name, internal visibility, and 13-argument signature.
   - Remove the `emit PeriodClosed(...)` block.
   - Replace `emit ControllerTransitionTrace(...)` with `emit PeriodTrace(...)`.
   - Update the function's NatSpec to: `Emits PeriodTrace for a closed period.`
3. Call sites at `_emitPeriodTrace` (lines 676, 748): no edits.

### `ops/tests/unit/VolumeDynamicFeeHook.Admin.t.sol`

1. Topic constants (around lines 199-203):
   - Delete `PERIOD_CLOSED_TOPIC`.
   - Rename `CONTROLLER_TRANSITION_TRACE_TOPIC` to `PERIOD_TRACE_TOPIC` and
     update the keccak input string to
     `"PeriodTrace(uint64,uint24,uint8,uint24,uint8,uint64,uint96,uint96,uint64,uint16,uint16,uint16,uint8)"`.
2. Log structs (around lines 207-232):
   - Delete `struct PeriodClosedLog`.
   - Rename `struct ControllerTransitionTraceLog` to `struct PeriodTraceLog`.
     Field set unchanged.
3. `SwapEventCapture` (around lines 241-249):
   - Remove `periodClosedCount` and `lastPeriodClosed` fields.
   - Keep `traceCount` and `lastTrace`. Change `lastTrace` type to
     `PeriodTraceLog`.
4. Log parser (around lines 450-506):
   - Remove the entire `if (topic0 == PERIOD_CLOSED_TOPIC) { ... }` branch.
   - In the surviving branch, switch the topic constant and the captured
     struct type to the renamed names.
5. Assertions across the test bodies (starting around line 673):
   - Replace every `capture.periodClosedCount` with `capture.traceCount`.
   - Replace every `capture.lastPeriodClosed.<X>` with `capture.lastTrace.<X>`.
     For the field name `emaVolumeScaled` (only present on the old
     `PeriodClosedLog`) use `emaVolumeAfter` from the new `PeriodTraceLog`;
     they describe the same EMA value.
   - Update assertion messages such as `"PeriodClosed must still emit"` to
     reference `PeriodTrace`.
6. Constants `TRACE_FLAG_*` are unchanged; they decode the `decisionBits`
   field, whose semantics are unchanged.

### `ops/tests/unit/MeasureGasLocalReport.t.sol`

Apply the same renaming and pruning as in `VolumeDynamicFeeHook.Admin.t.sol`:

- Drop `PERIOD_CLOSED_TOPIC`, rename `CONTROLLER_TRANSITION_TRACE_TOPIC` to
  `PERIOD_TRACE_TOPIC`.
- Drop `PeriodClosedLog` and aggregates `firstPeriodClosed`, `lastPeriodClosed`,
  `hasPeriodClosed`.
- Rename `ControllerTransitionTraceLog` to `PeriodTraceLog`; rename the
  capture fields to match.
- Remove the `PERIOD_CLOSED_TOPIC` branch in the parser. Update the surviving
  branch to the new topic and struct type.

### `docs/SPEC.md`

1. Section "Approximate LP fee metric" (around lines 253-258):
   Replace the existing wording with a single statement that the period-close
   event `PeriodTrace` emits `approxLpFeesUsd`, and that this metric is
   approximate telemetry only and not accounting-grade LP revenue.
2. Section title around line 260: rename "Period-close diagnostics" to
   "Period close trace".
3. Body of that section (lines 262-310):
   - New introduction: `PeriodTrace` is emitted on every period close inside
     `_afterSwap()` and on the explicit idle-reset path. It is not emitted
     for ordinary in-period swaps. `FeeUpdated` continues to emit independently
     and only when the active fee tier actually changes.
   - Remove every phrase that frames the event as a companion, addition, or
     replacement of another event. No "companion to", "additive event", "does
     not replace", "previously", "instead of".
   - Field semantics list: keep all field descriptions. Rewrite the
     `approxLpFeesUsd` line to: approximate LP fees telemetry for the closed
     period, computed against `fromFee`. Rewrite the `reasonCode` line to:
     controller reason code for the close decision.
   - Compact counter packing, decision-bit packing, and idle-reset trace
     semantics: keep as is, with no name substitutions other than dropping
     references to `PeriodClosed`.

### Files not touched

- PDF outputs in `docs/` and any source markdown in `docs/draft/` and
  `docs/ASSUMPTIONS.md`. None of them references the affected event names.
- `docs/index.html`. Not affected.
- Deployment scripts under `ops/optimism/`. Not affected.

## Verification plan

| Step | Command | Confirms |
| - | - | - |
| 1 | `forge build` | Contract compiles; no dangling references; runtime bytecode within EIP-170. |
| 2 | `forge test --match-path 'ops/tests/unit/VolumeDynamicFeeHook.Admin.t.sol' -vv` | Renamed parser, struct, and assertions pass across all controller scenarios (HOLD, JUMP_CASH, JUMP_EXTREME, idle reset, etc.). |
| 3 | `forge test --match-path 'ops/tests/unit/MeasureGasLocalReport.t.sol' -vv` | Gas report builds; the single `PeriodTrace` event is parsed correctly. |
| 4 | `forge test` | Full suite passes. Required because the change touches the hook's event API and may interact with controller fuzz / invariant / integration tests. |
| 5 | `grep -rn "PeriodClosed\|ControllerTransitionTrace\|PERIOD_CLOSED_TOPIC\|CONTROLLER_TRANSITION_TRACE_TOPIC" src ops/tests docs/SPEC.md` | No remaining references to the old names. |

## Out of scope

- Deployment of a new hook version on Optimism (separate release task).
- Off-chain indexer / dashboard migration (consumers of the v2.4.0 deployed
  hook are out of scope; this change targets the next deployable version).
- Any micro-optimization of `_emitPeriodTrace` argument layout, controller
  reason codes, or the bit-packing schemes themselves.
- Changes to `FeeUpdated`, `Paused`, `Unpaused`, `IdleReset`, or any other
  event.

## Definition of done

1. `forge build` succeeds.
2. `forge test` is green across the full suite.
3. The grep step in the verification plan returns no matches.
4. `docs/SPEC.md` reflects the final naming and emission rules.
5. Changes are committed with a descriptive message.
