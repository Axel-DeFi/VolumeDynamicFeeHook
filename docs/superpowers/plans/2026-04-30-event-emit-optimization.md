# Period-close event emission optimization — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drop the duplicated `PeriodClosed` event and rename
`ControllerTransitionTrace` to `PeriodTrace`, so that only one event with a
13-field payload is emitted on every period close.

**Architecture:** Single 13-field event `PeriodTrace` replaces the previous
8-field `PeriodClosed` + 13-field `ControllerTransitionTrace` pair. The
internal helper `_emitPeriodTrace` keeps its 13-argument signature and its
two call sites; only its body changes. All test parsers and assertions are
re-targeted at the new event. `docs/SPEC.md` is rewritten to describe only
the current behavior.

**Tech Stack:** Solidity 0.8.x, Foundry (`forge build`, `forge test`).

**Branch policy:** Work on `main`. Per project convention (recent commits
on `main`) and per the rule "do not create new branches without an explicit
request", no worktree or feature branch is created.

**Spec:** `docs/superpowers/specs/2026-04-30-event-emit-optimization-design.md`

---

## Task 1: Rename event in the hook contract

**Files:**
- Modify: `src/VolumeDynamicFeeHook.sol:212-245` (events declaration block)
- Modify: `src/VolumeDynamicFeeHook.sol:1703-1744` (`_emitPeriodTrace` body)

This task does not commit. The contract change leaves tests broken until
Tasks 2 and 3 land. The atomic commit happens in Task 4.

- [ ] **Step 1.1: Replace the events declaration block**

Open `src/VolumeDynamicFeeHook.sol`. Replace the entire range
`src/VolumeDynamicFeeHook.sol:212-245`, which currently is:

```solidity
    /// @notice Emitted for each period-close transition.
    event PeriodClosed(
        uint24 fromFee,
        uint8 fromFeeIdx,
        uint24 toFee,
        uint8 toFeeIdx,
        uint64 periodVolume,
        uint96 emaVolumeScaled,
        uint64 approxLpFeesUsd,
        uint8 reasonCode
    );

    /// @notice Emitted alongside `PeriodClosed` with compact controller diagnostics for the closed period.
    /// @dev `stateBitsBefore` / `stateBitsAfter` pack:
    /// bit 0 paused, bits 1..4 holdRemaining, bits 5..7 upExtremeStreak, bits 8..11 downStreak,
    /// bits 12..15 emergencyStreak.
    /// @dev `decisionBits` packs:
    /// bit 0 bootstrapV2, bit 2 holdWasActive, bit 3 emergencyTriggered,
    /// bit 4 cashEnterTrigger, bit 5 extremeEnterTrigger, bit 6 extremeExitTrigger, bit 7 cashExitTrigger.
    event ControllerTransitionTrace(
        uint64 periodStart,
        uint24 fromFee,
        uint8 fromFeeIdx,
        uint24 toFee,
        uint8 toFeeIdx,
        uint64 periodVolume,
        uint96 emaVolumeBefore,
        uint96 emaVolumeAfter,
        uint64 approxLpFeesUsd,
        uint16 decisionBits,
        uint16 stateBitsBefore,
        uint16 stateBitsAfter,
        uint8 reasonCode
    );
```

with:

```solidity
    /// @notice Emitted on every period close.
    /// @dev `stateBitsBefore` / `stateBitsAfter` pack:
    /// bit 0 paused, bits 1..4 holdRemaining, bits 5..7 upExtremeStreak, bits 8..11 downStreak,
    /// bits 12..15 emergencyStreak.
    /// @dev `decisionBits` packs:
    /// bit 0 bootstrapV2, bit 2 holdWasActive, bit 3 emergencyTriggered,
    /// bit 4 cashEnterTrigger, bit 5 extremeEnterTrigger, bit 6 extremeExitTrigger, bit 7 cashExitTrigger.
    event PeriodTrace(
        uint64 periodStart,
        uint24 fromFee,
        uint8 fromFeeIdx,
        uint24 toFee,
        uint8 toFeeIdx,
        uint64 periodVolume,
        uint96 emaVolumeBefore,
        uint96 emaVolumeAfter,
        uint64 approxLpFeesUsd,
        uint16 decisionBits,
        uint16 stateBitsBefore,
        uint16 stateBitsAfter,
        uint8 reasonCode
    );
```

- [ ] **Step 1.2: Replace the `_emitPeriodTrace` body**

Open `src/VolumeDynamicFeeHook.sol`. Replace the range
`src/VolumeDynamicFeeHook.sol:1703-1744`, which currently is:

```solidity
    /// @notice Emits both `PeriodClosed` and `ControllerTransitionTrace` for a closed period.
    function _emitPeriodTrace(
        uint64 periodStart,
        uint24 fromFee,
        uint8 fromFeeIdx,
        uint24 toFee,
        uint8 toFeeIdx,
        uint64 periodVolume,
        uint96 emaVolumeBefore,
        uint96 emaVolumeAfter,
        uint64 approxLpFeesUsd,
        uint16 decisionBits,
        uint16 stateBitsBefore,
        uint16 stateBitsAfter,
        uint8 reasonCode
    ) internal {
        emit PeriodClosed(
            fromFee,
            fromFeeIdx,
            toFee,
            toFeeIdx,
            periodVolume,
            emaVolumeAfter,
            approxLpFeesUsd,
            reasonCode
        );
        emit ControllerTransitionTrace(
            periodStart,
            fromFee,
            fromFeeIdx,
            toFee,
            toFeeIdx,
            periodVolume,
            emaVolumeBefore,
            emaVolumeAfter,
            approxLpFeesUsd,
            decisionBits,
            stateBitsBefore,
            stateBitsAfter,
            reasonCode
        );
    }
```

with:

```solidity
    /// @notice Emits `PeriodTrace` for a closed period.
    function _emitPeriodTrace(
        uint64 periodStart,
        uint24 fromFee,
        uint8 fromFeeIdx,
        uint24 toFee,
        uint8 toFeeIdx,
        uint64 periodVolume,
        uint96 emaVolumeBefore,
        uint96 emaVolumeAfter,
        uint64 approxLpFeesUsd,
        uint16 decisionBits,
        uint16 stateBitsBefore,
        uint16 stateBitsAfter,
        uint8 reasonCode
    ) internal {
        emit PeriodTrace(
            periodStart,
            fromFee,
            fromFeeIdx,
            toFee,
            toFeeIdx,
            periodVolume,
            emaVolumeBefore,
            emaVolumeAfter,
            approxLpFeesUsd,
            decisionBits,
            stateBitsBefore,
            stateBitsAfter,
            reasonCode
        );
    }
```

- [ ] **Step 1.3: Verify the contract compiles**

Run: `forge build`

Expected: success (no errors). Tests will not yet build because they still
reference the old event names — that is fixed in Tasks 2 and 3.

- [ ] **Step 1.4: Sanity-check there are no stale references in `src/`**

Run: `grep -n "PeriodClosed\|ControllerTransitionTrace" src/VolumeDynamicFeeHook.sol`

Expected: empty output.

---

## Task 2: Update `VolumeDynamicFeeHook.Admin.t.sol`

**Files:**
- Modify: `ops/tests/unit/VolumeDynamicFeeHook.Admin.t.sol`

This task does not commit. The atomic commit happens in Task 4.

- [ ] **Step 2.1: Replace the topic constants block**

In `ops/tests/unit/VolumeDynamicFeeHook.Admin.t.sol`, replace the range
`ops/tests/unit/VolumeDynamicFeeHook.Admin.t.sol:199-203`, currently:

```solidity
    bytes32 internal constant CONTROLLER_TRANSITION_TRACE_TOPIC = keccak256(
        "ControllerTransitionTrace(uint64,uint24,uint8,uint24,uint8,uint64,uint96,uint96,uint64,uint16,uint16,uint16,uint8)"
    );
    bytes32 internal constant PERIOD_CLOSED_TOPIC =
        keccak256("PeriodClosed(uint24,uint8,uint24,uint8,uint64,uint96,uint64,uint8)");
```

with:

```solidity
    bytes32 internal constant PERIOD_TRACE_TOPIC = keccak256(
        "PeriodTrace(uint64,uint24,uint8,uint24,uint8,uint64,uint96,uint96,uint64,uint16,uint16,uint16,uint8)"
    );
```

- [ ] **Step 2.2: Replace the log structs block**

Replace the range `ops/tests/unit/VolumeDynamicFeeHook.Admin.t.sol:207-232`,
currently:

```solidity
    struct ControllerTransitionTraceLog {
        uint64 periodStart;
        uint24 fromFee;
        uint8 fromFeeIdx;
        uint24 toFee;
        uint8 toFeeIdx;
        uint64 periodVolume;
        uint96 emaVolumeBefore;
        uint96 emaVolumeAfter;
        uint64 approxLpFeesUsd;
        uint16 decisionBits;
        uint16 stateBitsBefore;
        uint16 stateBitsAfter;
        uint8 reasonCode;
    }

    struct PeriodClosedLog {
        uint24 fromFee;
        uint8 fromFeeIdx;
        uint24 toFee;
        uint8 toFeeIdx;
        uint64 periodVolume;
        uint96 emaVolumeScaled;
        uint64 approxLpFeesUsd;
        uint8 reasonCode;
    }
```

with:

```solidity
    struct PeriodTraceLog {
        uint64 periodStart;
        uint24 fromFee;
        uint8 fromFeeIdx;
        uint24 toFee;
        uint8 toFeeIdx;
        uint64 periodVolume;
        uint96 emaVolumeBefore;
        uint96 emaVolumeAfter;
        uint64 approxLpFeesUsd;
        uint16 decisionBits;
        uint16 stateBitsBefore;
        uint16 stateBitsAfter;
        uint8 reasonCode;
    }
```

- [ ] **Step 2.3: Update `SwapEventCapture`**

Replace the range `ops/tests/unit/VolumeDynamicFeeHook.Admin.t.sol:241-249`,
currently:

```solidity
    struct SwapEventCapture {
        uint256 traceCount;
        uint256 periodClosedCount;
        uint256 feeUpdatedCount;
        uint256 idleResetCount;
        ControllerTransitionTraceLog lastTrace;
        PeriodClosedLog lastPeriodClosed;
        FeeUpdatedLog lastFeeUpdated;
    }
```

with:

```solidity
    struct SwapEventCapture {
        uint256 traceCount;
        uint256 feeUpdatedCount;
        uint256 idleResetCount;
        PeriodTraceLog lastTrace;
        FeeUpdatedLog lastFeeUpdated;
    }
```

- [ ] **Step 2.4: Update the parser**

In the parser block around `ops/tests/unit/VolumeDynamicFeeHook.Admin.t.sol:438-506`,
two edits:

(a) Replace the topic check that reads `CONTROLLER_TRANSITION_TRACE_TOPIC`
with `PERIOD_TRACE_TOPIC`. The struct literal `ControllerTransitionTraceLog({...})`
inside that branch becomes `PeriodTraceLog({...})`. All field names stay the
same.

(b) Delete the entire branch starting at
`ops/tests/unit/VolumeDynamicFeeHook.Admin.t.sol:483`:

```solidity
            if (topic0 == PERIOD_CLOSED_TOPIC) {
                capture.periodClosedCount += 1;
                (
                    uint24 fromFee_,
                    uint8 fromFeeIdx_,
                    uint24 toFee_,
                    uint8 toFeeIdx_,
                    uint64 periodVolume_,
                    uint96 emaVolumeScaled_,
                    uint64 approxLpFeesUsd_,
                    uint8 reasonCode_
                ) = abi.decode(entries[i].data, (uint24, uint8, uint24, uint8, uint64, uint96, uint64, uint8));
                capture.lastPeriodClosed = PeriodClosedLog({
                    fromFee: fromFee_,
                    fromFeeIdx: fromFeeIdx_,
                    toFee: toFee_,
                    toFeeIdx: toFeeIdx_,
                    periodVolume: periodVolume_,
                    emaVolumeScaled: emaVolumeScaled_,
                    approxLpFeesUsd: approxLpFeesUsd_,
                    reasonCode: reasonCode_
                });
                continue;
            }
```

After the edit, only the `PERIOD_TRACE_TOPIC`, `FEE_UPDATED_TOPIC` and
`IDLE_RESET_TOPIC` branches remain (plus any other unrelated topic checks
already present in this loop).

- [ ] **Step 2.5: Replace assertions across the test bodies**

In the same file, perform a manual search-and-edit (do NOT use blind sed —
some occurrences need a field rename, not just a name swap):

(a) Every `capture.periodClosedCount` becomes `capture.traceCount`.
(b) Every `capture.lastPeriodClosed.<field>` becomes `capture.lastTrace.<field>`,
with one field-name substitution: `emaVolumeScaled` becomes `emaVolumeAfter`.
The other field names (`fromFee`, `fromFeeIdx`, `toFee`, `toFeeIdx`,
`periodVolume`, `approxLpFeesUsd`, `reasonCode`) are identical between the
old and new struct.
(c) Every assertion message that contains the literal `PeriodClosed` is
rewritten to use `PeriodTrace`. Examples:
- `"PeriodClosed must not emit on open-period swaps"` → `"PeriodTrace must not emit on open-period swaps"`.
- `"PeriodClosed must still emit"` → `"PeriodTrace must emit"` (drop the
  word "still" — it described the previous state where Trace was added on
  top of Closed, which no longer applies).

To make this efficient, run these greps first to enumerate every line:

```bash
grep -n "periodClosedCount" ops/tests/unit/VolumeDynamicFeeHook.Admin.t.sol
grep -n "lastPeriodClosed"  ops/tests/unit/VolumeDynamicFeeHook.Admin.t.sol
grep -n "PeriodClosed"       ops/tests/unit/VolumeDynamicFeeHook.Admin.t.sol
```

Each enumerated line must be updated according to (a), (b), (c). After the
edits, none of the three greps should return any line.

- [ ] **Step 2.6: Verify the file compiles and Admin tests pass**

Run: `forge build`

Expected: success.

Run: `forge test --match-path 'ops/tests/unit/VolumeDynamicFeeHook.Admin.t.sol' -vv`

Expected: every test in the file passes.

If any test fails with a parser error such as "no event matched topic", the
keccak input string in Step 2.1 was mistyped. Compare it against the event
declaration in `src/VolumeDynamicFeeHook.sol` from Task 1 character by
character.

---

## Task 3: Update `MeasureGasLocalReport.t.sol`

**Files:**
- Modify: `ops/tests/unit/MeasureGasLocalReport.t.sol`

This task does not commit. The atomic commit happens in Task 4.

The structure mirrors Task 2 but the file additionally maintains a
"first/last" pair for the trace, a "first/last" pair for `PeriodClosed`, and
a cross-check helper `_assertReasonTalliesAligned` that compares trace
reason counts against `PeriodClosed` reason counts. After consolidation to
a single event the cross-check becomes a tautology and is deleted.

- [ ] **Step 3.1: Update `LogCounts` struct**

Replace the range `ops/tests/unit/MeasureGasLocalReport.t.sol:44-50`,
currently:

```solidity
    struct LogCounts {
        uint256 periodClosedCount;
        uint256 traceCount;
        uint256 idleResetCount;
        uint256 feeUpdatedCount;
        uint256 claimCount;
    }
```

with:

```solidity
    struct LogCounts {
        uint256 traceCount;
        uint256 idleResetCount;
        uint256 feeUpdatedCount;
        uint256 claimCount;
    }
```

- [ ] **Step 3.2: Replace log structs block**

Replace the range `ops/tests/unit/MeasureGasLocalReport.t.sol:84-109`,
currently:

```solidity
    struct ControllerTransitionTraceLog {
        uint64 periodStart;
        uint24 fromFee;
        uint8 fromFeeIdx;
        uint24 toFee;
        uint8 toFeeIdx;
        uint64 periodVolume;
        uint96 emaVolumeBefore;
        uint96 emaVolumeAfter;
        uint64 approxLpFeesUsd;
        uint16 decisionBits;
        uint16 stateBitsBefore;
        uint16 stateBitsAfter;
        uint8 reasonCode;
    }

    struct PeriodClosedLog {
        uint24 fromFee;
        uint8 fromFeeIdx;
        uint24 toFee;
        uint8 toFeeIdx;
        uint64 periodVolume;
        uint96 emaVolumeScaled;
        uint64 approxLpFeesUsd;
        uint8 reasonCode;
    }
```

with:

```solidity
    struct PeriodTraceLog {
        uint64 periodStart;
        uint24 fromFee;
        uint8 fromFeeIdx;
        uint24 toFee;
        uint8 toFeeIdx;
        uint64 periodVolume;
        uint96 emaVolumeBefore;
        uint96 emaVolumeAfter;
        uint64 approxLpFeesUsd;
        uint16 decisionBits;
        uint16 stateBitsBefore;
        uint16 stateBitsAfter;
        uint8 reasonCode;
    }
```

- [ ] **Step 3.3: Update `ScenarioLogCapture`**

Replace the range `ops/tests/unit/MeasureGasLocalReport.t.sol:111-121`,
currently:

```solidity
    struct ScenarioLogCapture {
        LogCounts counts;
        ReasonCounts traceReasons;
        ReasonCounts periodClosedReasons;
        ControllerTransitionTraceLog firstTrace;
        ControllerTransitionTraceLog lastTrace;
        PeriodClosedLog firstPeriodClosed;
        PeriodClosedLog lastPeriodClosed;
        bool hasTrace;
        bool hasPeriodClosed;
    }
```

with:

```solidity
    struct ScenarioLogCapture {
        LogCounts counts;
        ReasonCounts traceReasons;
        PeriodTraceLog firstTrace;
        PeriodTraceLog lastTrace;
        bool hasTrace;
    }
```

- [ ] **Step 3.4: Update the topic constants**

Replace the range `ops/tests/unit/MeasureGasLocalReport.t.sol:131-135`,
currently:

```solidity
    bytes32 internal constant PERIOD_CLOSED_SIG =
        keccak256("PeriodClosed(uint24,uint8,uint24,uint8,uint64,uint96,uint64,uint8)");
    bytes32 internal constant TRACE_SIG = keccak256(
        "ControllerTransitionTrace(uint64,uint24,uint8,uint24,uint8,uint64,uint96,uint96,uint64,uint16,uint16,uint16,uint8)"
    );
```

with:

```solidity
    bytes32 internal constant PERIOD_TRACE_SIG = keccak256(
        "PeriodTrace(uint64,uint24,uint8,uint24,uint8,uint64,uint96,uint96,uint64,uint16,uint16,uint16,uint8)"
    );
```

- [ ] **Step 3.5: Update the parser — trace branch**

In the parser block around line 2030-2087, the trace branch currently
checks `topic0 == TRACE_SIG`, increments `capture.counts.traceCount`,
decodes the 13-field tuple, and assigns it to a
`ControllerTransitionTraceLog({...})` literal. Two substitutions:

- `TRACE_SIG` becomes `PERIOD_TRACE_SIG`.
- `ControllerTransitionTraceLog({...})` becomes `PeriodTraceLog({...})`.

Field names inside the literal are unchanged.

- [ ] **Step 3.6: Update the parser — delete the `PERIOD_CLOSED_SIG` branch**

Delete the entire branch at `ops/tests/unit/MeasureGasLocalReport.t.sol:2089-2118`,
currently:

```solidity
            if (topic0 == PERIOD_CLOSED_SIG) {
                capture.counts.periodClosedCount += 1;
                (
                    uint24 fromFee_,
                    uint8 fromFeeIdx_,
                    uint24 toFee_,
                    uint8 toFeeIdx_,
                    uint64 periodVolume_,
                    uint96 emaVolumeScaled_,
                    uint64 approxLpFeesUsd_,
                    uint8 reasonCode_
                ) = abi.decode(logs[i].data, (uint24, uint8, uint24, uint8, uint64, uint96, uint64, uint8));

                capture.lastPeriodClosed = PeriodClosedLog({
                    fromFee: fromFee_,
                    fromFeeIdx: fromFeeIdx_,
                    toFee: toFee_,
                    toFeeIdx: toFeeIdx_,
                    periodVolume: periodVolume_,
                    emaVolumeScaled: emaVolumeScaled_,
                    approxLpFeesUsd: approxLpFeesUsd_,
                    reasonCode: reasonCode_
                });
                if (!capture.hasPeriodClosed) {
                    capture.firstPeriodClosed = capture.lastPeriodClosed;
                    capture.hasPeriodClosed = true;
                }
                capture.periodClosedReasons = _incrementReasonCounts(capture.periodClosedReasons, reasonCode_);
                continue;
            }
```

- [ ] **Step 3.7: Delete the cross-check helper and its single call site**

Delete the entire function `_assertReasonTalliesAligned` from
`ops/tests/unit/MeasureGasLocalReport.t.sol:2155-2200`, including its
opening `function` declaration and the closing `}`. After consolidation to
one event the helper is a tautology (compares `traceReasons` to itself).

Then delete the single call site at
`ops/tests/unit/MeasureGasLocalReport.t.sol:946`:

```solidity
        _assertReasonTalliesAligned(capture);
```

Use grep to confirm there are no other call sites:

Run: `grep -n "_assertReasonTalliesAligned" ops/tests/unit/MeasureGasLocalReport.t.sol`

Expected: empty.

- [ ] **Step 3.8: Replace `counts.periodClosedCount` assertions**

Run: `grep -n "periodClosedCount" ops/tests/unit/MeasureGasLocalReport.t.sol`

Replace every match with `traceCount`. The assertion messages reference
"closed period" / "close" wording; rewrite each to refer to the period-trace
event. Examples:

- `"normal swap must not close a period"` — keep as is (refers to
  semantics, not to the specific event name).
- `"single close must close exactly one elapsed period"` — keep as is
  (semantic description).
- `"floor->cash path must close exactly one elapsed period"` — keep.

The semantics-oriented messages do not name the event and stay valid.

After the substitution, run: `grep -n "periodClosedCount" ops/tests/unit/MeasureGasLocalReport.t.sol`

Expected: empty.

- [ ] **Step 3.9: Verify gas-report tests compile and pass**

Run: `forge build`

Expected: success.

Run: `forge test --match-path 'ops/tests/unit/MeasureGasLocalReport.t.sol' -vv`

Expected: every test in the file passes.

---

## Task 4: Full test run + commit code change

**Files:**
- Already-modified: `src/VolumeDynamicFeeHook.sol`,
  `ops/tests/unit/VolumeDynamicFeeHook.Admin.t.sol`,
  `ops/tests/unit/MeasureGasLocalReport.t.sol`.

- [ ] **Step 4.1: Final grep across code**

Run:

```bash
grep -rn "PeriodClosed\|ControllerTransitionTrace\|PERIOD_CLOSED_TOPIC\|PERIOD_CLOSED_SIG\|CONTROLLER_TRANSITION_TRACE_TOPIC\|TRACE_SIG\b" src ops/tests
```

Expected: empty output. If anything remains, address it before continuing.

- [ ] **Step 4.2: Run the full test suite**

Per project CLAUDE.md, a full run is required for changes to the hook's
event API.

Run: `forge test`

Expected: all tests pass. If any non-trivially-related suite fails, stop
and investigate; do not paper over with skips.

- [ ] **Step 4.3: Commit code and tests as one atomic change**

```bash
git add src/VolumeDynamicFeeHook.sol \
        ops/tests/unit/VolumeDynamicFeeHook.Admin.t.sol \
        ops/tests/unit/MeasureGasLocalReport.t.sol
git commit -m "$(cat <<'EOF'
refactor(hook): merge PeriodClosed into renamed PeriodTrace event

PeriodClosed duplicated 7 of 8 fields already present in
ControllerTransitionTrace; both were emitted on every period close,
costing the closing swapper extra gas on each period boundary and adding
log noise. PeriodClosed is removed and ControllerTransitionTrace is
renamed to PeriodTrace, so a single 13-field event is emitted per close.

The internal helper _emitPeriodTrace keeps its name and 13-argument
signature; only its body changes from two emits to one.

ABI break: consumers must migrate from the PeriodClosed and
ControllerTransitionTrace topics to the new PeriodTrace topic.
EOF
)"
```

- [ ] **Step 4.4: Verify the commit**

Run: `git log -1 --stat`

Expected: one commit touching exactly the three files above.

---

## Task 5: Update `docs/SPEC.md`

**Files:**
- Modify: `docs/SPEC.md` — sections "Approximate LP fee metric"
  (lines 253-258) and "Period-close diagnostics" (lines 260-310).

- [ ] **Step 5.1: Replace the "Approximate LP fee metric" section**

Replace the range `docs/SPEC.md:253-258`, currently:

```markdown
## Approximate LP fee metric

`PeriodClosed` emits:
- `approxLpFeesUsd`

This metric is approximate telemetry only, not accounting-grade LP revenue.
```

with:

```markdown
## Approximate LP fee metric

The period-close event `PeriodTrace` emits `approxLpFeesUsd`. This metric is
approximate telemetry only, not accounting-grade LP revenue.
```

- [ ] **Step 5.2: Replace the "Period-close diagnostics" section**

Replace the entire range `docs/SPEC.md:260-310` (heading through the end of
the "Idle reset trace semantics" subsection), currently starting:

```markdown
## Period-close diagnostics

`ControllerTransitionTrace` is emitted as a compact telemetry companion to `PeriodClosed`.
It is an additive event only and does not replace `PeriodClosed` or `FeeUpdated`.

Emission rules:
- emits only on period-close path inside `_afterSwap()` and on the explicit idle-reset path,
- does not emit for ordinary in-period swaps,
- keeps existing event behavior unchanged:
  `PeriodClosed` still emits for every close, `FeeUpdated` still emits only when active fee actually changes.

Field semantics:
- `periodStart`: start timestamp of the period being closed. In multi-close catch-up, this advances by `periodSeconds` per closed period.
- `fromFee` / `fromFeeIdx`: mode before controller evaluation for this closed period.
- `toFee` / `toFeeIdx`: mode after controller evaluation for this closed period.
- `periodVolume`: counted volume of the closed period (`0` for zero-volume catch-up closes and idle reset).
- `emaVolumeBefore`: EMA before `_updateEmaScaled(...)`.
- `emaVolumeAfter`: EMA immediately after `_updateEmaScaled(...)`. This is still non-zero for ordinary zero-volume closes; only idle reset forces it to `0`.
- `approxLpFeesUsd`: same approximate telemetry metric as `PeriodClosed`, based on `fromFee`.
- `reasonCode`: unchanged controller reason code already used by `PeriodClosed`.

Compact counter packing:
- `stateBitsBefore` and `stateBitsAfter` use:
  bit `0` paused,
  bits `1..4` holdRemaining,
  bits `5..7` upExtremeStreak,
  bits `8..11` downStreak,
  bits `12..15` emergencyStreak.
- These fields describe the controller state immediately before and immediately after the close evaluation, not the long-lived packed `_state` bit positions.

Compact decision bit packing:
- bit `0`: `bootstrapV2`
- bit `2`: `holdWasActive`
- bit `3`: `emergencyTriggered`
- bit `4`: `cashEnterTrigger`
- bit `5`: `extremeEnterTrigger`
- bit `6`: `extremeExitTrigger`
- bit `7`: `cashExitTrigger`

Interpretation notes:
- `holdWasActive` refers to the pre-decrement hold state at close start; `stateBitsAfter` reflects post-decrement/post-transition state.
- `emergencyTriggered` means the automatic emergency-floor rule fired before ordinary mode logic.
- trigger flags are diagnostic hints for which transition thresholds were met on that close; they do not imply a transition actually happened.

Idle reset trace semantics:
- `periodVolume = 0`
- `emaVolumeBefore =` previous EMA
- `emaVolumeAfter = 0`
- `approxLpFeesUsd = 0`
- `decisionBits = 0`
- `stateBitsBefore` captures the pre-reset controller state and `stateBitsAfter` is the zeroed post-reset state.
```

with:

```markdown
## Period close trace

`PeriodTrace` is emitted on every period close inside `_afterSwap()` and on
the explicit idle-reset path. It is not emitted for ordinary in-period
swaps. `FeeUpdated` continues to emit independently and only when the
active fee tier actually changes.

Field semantics:
- `periodStart`: start timestamp of the period being closed. In multi-close catch-up, this advances by `periodSeconds` per closed period.
- `fromFee` / `fromFeeIdx`: mode before controller evaluation for this closed period.
- `toFee` / `toFeeIdx`: mode after controller evaluation for this closed period.
- `periodVolume`: counted volume of the closed period (`0` for zero-volume catch-up closes and idle reset).
- `emaVolumeBefore`: EMA before `_updateEmaScaled(...)`.
- `emaVolumeAfter`: EMA immediately after `_updateEmaScaled(...)`. This is still non-zero for ordinary zero-volume closes; only idle reset forces it to `0`.
- `approxLpFeesUsd`: approximate LP fees telemetry for the closed period, computed against `fromFee`.
- `reasonCode`: controller reason code for the close decision.

Compact counter packing:
- `stateBitsBefore` and `stateBitsAfter` use:
  bit `0` paused,
  bits `1..4` holdRemaining,
  bits `5..7` upExtremeStreak,
  bits `8..11` downStreak,
  bits `12..15` emergencyStreak.
- These fields describe the controller state immediately before and immediately after the close evaluation, not the long-lived packed `_state` bit positions.

Compact decision bit packing:
- bit `0`: `bootstrapV2`
- bit `2`: `holdWasActive`
- bit `3`: `emergencyTriggered`
- bit `4`: `cashEnterTrigger`
- bit `5`: `extremeEnterTrigger`
- bit `6`: `extremeExitTrigger`
- bit `7`: `cashExitTrigger`

Interpretation notes:
- `holdWasActive` refers to the pre-decrement hold state at close start; `stateBitsAfter` reflects post-decrement/post-transition state.
- `emergencyTriggered` means the automatic emergency-floor rule fired before ordinary mode logic.
- trigger flags are diagnostic hints for which transition thresholds were met on that close; they do not imply a transition actually happened.

Idle reset trace semantics:
- `periodVolume = 0`
- `emaVolumeBefore =` previous EMA
- `emaVolumeAfter = 0`
- `approxLpFeesUsd = 0`
- `decisionBits = 0`
- `stateBitsBefore` captures the pre-reset controller state and `stateBitsAfter` is the zeroed post-reset state.
```

- [ ] **Step 5.3: Verify SPEC has no leftover references**

Run: `grep -n "PeriodClosed\|ControllerTransitionTrace" docs/SPEC.md`

Expected: empty output.

- [ ] **Step 5.4: Commit SPEC changes**

```bash
git add docs/SPEC.md
git commit -m "$(cat <<'EOF'
docs(spec): rewrite period-close section for the unified PeriodTrace event

Reflects the contract change that removed PeriodClosed and renamed
ControllerTransitionTrace to PeriodTrace. The "Period-close diagnostics"
heading becomes "Period close trace" and the body describes only current
behavior, with no references to the removed event.
EOF
)"
```

---

## Task 6: Final verification across the project

- [ ] **Step 6.1: Project-wide grep**

Run:

```bash
grep -rn "PeriodClosed\|ControllerTransitionTrace\|PERIOD_CLOSED_TOPIC\|PERIOD_CLOSED_SIG\|CONTROLLER_TRANSITION_TRACE_TOPIC\|TRACE_SIG\b" src ops/tests docs/SPEC.md docs/draft docs/ASSUMPTIONS.md
```

Expected: empty output.

- [ ] **Step 6.2: Confirm full test suite is still green**

Run: `forge test`

Expected: pass.

- [ ] **Step 6.3: Inspect commit log**

Run: `git log --oneline -5`

Expected: the most recent two commits are the SPEC docs commit and the
contract+tests refactor commit, in that order. No accidental extra
commits.

- [ ] **Step 6.4: Report**

State:
- what was changed (events + helper body + tests + SPEC),
- what verifies the result (`forge test` full pass, project-wide grep
  empty, two commits with descriptive messages),
- residual risks (off-chain consumers of the deployed v2.4.0 hook keep
  parsing old topics — not addressed in this change; release of a new
  hook version is a separate task).

The change is not pushed to remote in this task; the user pushes when
they choose. Do not push automatically.
