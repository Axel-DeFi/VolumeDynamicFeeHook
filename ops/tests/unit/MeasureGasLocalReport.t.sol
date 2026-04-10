// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {GasMeasurementLocalBase} from "../../local/foundry/GasMeasurementLocalBase.sol";
import {GasMeasurementLib} from "../../shared/lib/GasMeasurementLib.sol";
import {OpsTypes} from "../../shared/types/OpsTypes.sol";

contract MeasureGasLocalReportTest is Test, GasMeasurementLocalBase {
    enum Scenario {
        NormalSwap,
        CloseOnePeriodNoTransition,
        CloseOnePeriodFloorToCash,
        CloseOnePeriodCashToFloor,
        CloseGap2PeriodsCashToFloor,
        CloseEmergencyCashToFloor,
        IdleReset,
        CloseGap2PeriodsNoTransition,
        CloseGap8PeriodsNoTransition,
        CloseGap23PeriodsNoTransition,
        CloseGap2PeriodsWithFloorToCash
    }

    struct LogCounts {
        uint256 periodClosedCount;
        uint256 traceCount;
        uint256 idleResetCount;
        uint256 feeUpdatedCount;
    }

    struct CounterSnapshot {
        uint256 updateBefore;
    }

    struct StateSnapshot {
        uint8 feeIdx;
        uint8 holdRemaining;
        uint8 upExtremeStreak;
        uint8 downStreak;
        uint8 emergencyStreak;
        uint64 periodStart;
        uint64 periodVolume;
        uint96 emaVolumeScaled;
        bool paused;
    }

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

    struct ScenarioLogCapture {
        LogCounts counts;
        ControllerTransitionTraceLog lastTrace;
        PeriodClosedLog lastPeriodClosed;
    }

    uint64 internal constant GAP_2_PERIODS = 2;
    uint64 internal constant GAP_8_PERIODS = 8;
    uint64 internal constant GAP_23_PERIODS = 23;
    uint16 internal constant TRACE_FLAG_EMERGENCY_TRIGGERED = 0x0008;

    bytes32 internal constant PERIOD_CLOSED_SIG =
        keccak256("PeriodClosed(uint24,uint8,uint24,uint8,uint64,uint96,uint64,uint8)");
    bytes32 internal constant TRACE_SIG =
        keccak256(
            "ControllerTransitionTrace(uint64,uint24,uint8,uint24,uint8,uint64,uint96,uint96,uint64,uint16,uint16,uint16,uint8)"
        );
    bytes32 internal constant IDLE_RESET_SIG = keccak256("IdleReset(uint24,uint8)");
    bytes32 internal constant FEE_UPDATED_SIG = keccak256("FeeUpdated(uint24,uint8,uint64,uint96)");

    function _loadMeasurementConfig() internal view override returns (OpsTypes.CoreConfig memory cfg) {
        cfg.runtime = OpsTypes.Runtime.Local;
        cfg.privateKey = 1;
        cfg.tickSpacing = 10;
        cfg.stableDecimals = 6;
        cfg.floorFeePips = 400;
        cfg.cashFeePips = 2_500;
        cfg.extremeFeePips = 9_000;
        cfg.periodSeconds = 60;
        cfg.emaPeriods = 8;
        cfg.idleResetSeconds = 60 * 24;
        cfg.hookFeePercent = 10;
        cfg.dustSwapThreshold = 4_000_000;
        cfg.enterCashMinVolume = 1_000 * 1e6;
        cfg.enterCashEmaRatioPct = 185;
        cfg.holdCashPeriods = 4;
        cfg.enterExtremeMinVolume = 4_000 * 1e6;
        cfg.enterExtremeEmaRatioPct = 405;
        cfg.enterExtremeConfirmPeriods = 2;
        cfg.holdExtremePeriods = 4;
        cfg.exitExtremeEmaRatioPct = 125;
        cfg.exitExtremeConfirmPeriods = 2;
        cfg.exitCashEmaRatioPct = 125;
        cfg.exitCashConfirmPeriods = 3;
        cfg.lowVolumeReset = 600 * 1e6;
        cfg.lowVolumeResetPeriods = 3;
    }

    function testGas_normal_swap() public {
        _runMeasuredScenario(Scenario.NormalSwap);
    }

    function testGas_close_one_period_no_transition() public {
        _runMeasuredScenario(Scenario.CloseOnePeriodNoTransition);
    }

    function testGas_close_one_period_floor_to_cash() public {
        _runMeasuredScenario(Scenario.CloseOnePeriodFloorToCash);
    }

    function testGas_close_one_period_cash_to_floor() public {
        _runMeasuredScenario(Scenario.CloseOnePeriodCashToFloor);
    }

    function testGas_close_gap_2_periods_cash_to_floor() public {
        _runMeasuredScenario(Scenario.CloseGap2PeriodsCashToFloor);
    }

    function testGas_close_emergency_cash_to_floor() public {
        _runMeasuredScenario(Scenario.CloseEmergencyCashToFloor);
    }

    function testGas_idle_reset() public {
        _runMeasuredScenario(Scenario.IdleReset);
    }

    function testGas_close_gap_2_periods_no_transition() public {
        _runMeasuredScenario(Scenario.CloseGap2PeriodsNoTransition);
    }

    function testGas_close_gap_8_periods_no_transition() public {
        _runMeasuredScenario(Scenario.CloseGap8PeriodsNoTransition);
    }

    function testGas_close_gap_23_periods_no_transition() public {
        _runMeasuredScenario(Scenario.CloseGap23PeriodsNoTransition);
    }

    function testGas_close_gap_2_periods_with_floor_to_cash() public {
        _runMeasuredScenario(Scenario.CloseGap2PeriodsWithFloorToCash);
    }

    function _runMeasuredScenario(Scenario scenario) internal {
        vm.pauseGasMetering();
        _setUpScenario(scenario);
        StateSnapshot memory beforeState = _captureState();

        CounterSnapshot memory snapshot = CounterSnapshot({updateBefore: manager.updateCount()});

        vm.recordLogs();
        vm.resumeGasMetering();
        _executeScenario(scenario);
        vm.pauseGasMetering();

        StateSnapshot memory afterState = _captureState();
        _assertScenario(scenario, beforeState, afterState, vm.getRecordedLogs(), snapshot);
    }

    function _setUpScenario(Scenario scenario) internal {
        _setUpMeasurementEnv();

        if (scenario == Scenario.NormalSwap) {
            _swapStable(_minCountedStableRaw());
            return;
        }

        if (scenario == Scenario.CloseOnePeriodNoTransition) {
            _swapStable(_seedStableRaw());
            _warpPeriods(1);
            return;
        }

        if (scenario == Scenario.CloseOnePeriodFloorToCash) {
            // Measured call closes one qualifying period and transitions FLOOR -> CASH.
            _primeFloorToCash();
            _warpPeriods(1);
            return;
        }

        if (scenario == Scenario.CloseOnePeriodCashToFloor) {
            _setUpCloseOnePeriodCashToFloor();
            return;
        }

        if (scenario == Scenario.CloseGap2PeriodsCashToFloor) {
            _setUpCloseGap2PeriodsCashToFloor();
            return;
        }

        if (scenario == Scenario.CloseEmergencyCashToFloor) {
            _setUpCloseEmergencyCashToFloor();
            return;
        }

        if (scenario == Scenario.IdleReset) {
            _moveToCash();
            vm.warp(block.timestamp + uint256(cfg.idleResetSeconds) + 1);
            return;
        }

        if (scenario == Scenario.CloseGap2PeriodsNoTransition) {
            _prepareGapClose(GAP_2_PERIODS);
            return;
        }

        if (scenario == Scenario.CloseGap8PeriodsNoTransition) {
            _prepareGapClose(GAP_8_PERIODS);
            return;
        }

        if (scenario == Scenario.CloseGap23PeriodsNoTransition) {
            _prepareGapClose(GAP_23_PERIODS);
            return;
        }

        if (scenario == Scenario.CloseGap2PeriodsWithFloorToCash) {
            // Measured call closes two missed periods and includes a FLOOR -> CASH transition.
            _primeFloorToCash();
            _warpPeriods(GAP_2_PERIODS);
        }
    }

    function _executeScenario(Scenario scenario) internal {
        _swapStable(_measuredSwapAmountStableRaw(scenario));
    }

    function _prepareGapClose(uint64 periods) internal {
        require(periods > 1, "gap periods too small");
        require(periods * uint64(cfg.periodSeconds) < uint64(cfg.idleResetSeconds), "gap close crosses idle reset");

        _swapStable(_seedStableRaw());
        _warpPeriods(periods);
    }

    function _setUpCloseOnePeriodCashToFloor() internal {
        // Ordinary CASH -> FLOOR path: hold is already exhausted before the measured close.
        _enterCashWithOrdinaryWeakOpenPeriod();

        uint256 weakClosesBeforeMeasurement =
            uint256(cfg.holdCashPeriods) + uint256(cfg.exitCashConfirmPeriods) - 2;

        for (uint256 i = 0; i < weakClosesBeforeMeasurement; ++i) {
            _advanceCashOrdinaryWeakClose();
        }

        StateSnapshot memory preState = _captureState();
        assertEq(preState.feeIdx, hook.MODE_CASH(), "immediate-down setup must start in cash");
        assertEq(preState.holdRemaining, 0, "immediate-down setup must exhaust hold before measurement");
        assertEq(
            preState.downStreak,
            cfg.exitCashConfirmPeriods - 1,
            "immediate-down setup must be one ordinary close short of floor"
        );
        assertEq(preState.emergencyStreak, 0, "immediate-down setup must avoid emergency reset");

        _warpPeriods(1);
    }

    function _setUpCloseGap2PeriodsCashToFloor() internal {
        // Ordinary CASH -> FLOOR path across a 2-period gap; hold is already exhausted before the gap begins.
        require(cfg.exitCashConfirmPeriods >= 3, "gap down needs >=3 confirms");
        require(
            GAP_2_PERIODS * uint64(cfg.periodSeconds) < uint64(cfg.idleResetSeconds),
            "gap down crosses idle reset"
        );

        _enterCashWithOrdinaryWeakOpenPeriod();

        uint256 weakClosesBeforeGap =
            uint256(cfg.holdCashPeriods) + uint256(cfg.exitCashConfirmPeriods) - 3;

        for (uint256 i = 0; i < weakClosesBeforeGap; ++i) {
            _advanceCashOrdinaryWeakClose();
        }

        StateSnapshot memory preGapState = _captureState();
        assertEq(preGapState.feeIdx, hook.MODE_CASH(), "gap-down setup must start in cash");
        assertEq(preGapState.holdRemaining, 0, "gap-down setup must finish hold before the gap begins");
        assertEq(
            preGapState.downStreak,
            cfg.exitCashConfirmPeriods - 2,
            "gap-down setup must leave two missed closes for the ordinary descent"
        );
        assertEq(preGapState.emergencyStreak, 0, "gap-down setup must avoid emergency reset before the gap");

        _warpPeriods(GAP_2_PERIODS);
    }

    function _setUpCloseEmergencyCashToFloor() internal {
        // Emergency CASH -> FLOOR path: the measured close is the one that completes the low-volume streak.
        _enterCashWithEmergencyWeakOpenPeriod();

        uint256 lowClosesBeforeMeasurement = uint256(cfg.lowVolumeResetPeriods) - 1;
        for (uint256 i = 0; i < lowClosesBeforeMeasurement; ++i) {
            _warpPeriods(1);
            _swapStable(_minCountedStableRaw());
            _assertMode(hook.MODE_CASH());
        }

        StateSnapshot memory preState = _captureState();
        assertEq(preState.feeIdx, hook.MODE_CASH(), "emergency-down setup must start in cash");
        assertGt(preState.holdRemaining, 0, "emergency-down setup must keep ordinary hold active");
        assertEq(preState.downStreak, 0, "emergency-down setup must not rely on ordinary down confirms");
        assertEq(
            preState.emergencyStreak,
            cfg.lowVolumeResetPeriods - 1,
            "emergency-down setup must be one low-volume close short of reset"
        );

        _warpPeriods(1);
    }

    function _enterCashWithOrdinaryWeakOpenPeriod() internal {
        _primeFloorToCash();
        _completeFloorToCash(_chooseNextDownOpenPeriodUsd6(cfg.exitCashEmaRatioPct));
        _assertMode(hook.MODE_CASH());
    }

    function _enterCashWithEmergencyWeakOpenPeriod() internal {
        _primeFloorToCash();
        _completeFloorToCash(_minCountedUsd6());
        _assertMode(hook.MODE_CASH());
    }

    function _advanceCashOrdinaryWeakClose() internal {
        _warpPeriods(1);
        _swapStable(_ordinaryCashWeakStableRaw());
        _assertMode(hook.MODE_CASH());
    }

    function _ordinaryCashWeakStableRaw() internal view returns (uint256) {
        return
            GasMeasurementLib.usd6ToStableRaw(
                _chooseNextDownOpenPeriodUsd6(cfg.exitCashEmaRatioPct), cfg.stableDecimals
            );
    }

    function _measuredSwapAmountStableRaw(Scenario scenario) internal view returns (uint256) {
        if (scenario == Scenario.CloseOnePeriodCashToFloor || scenario == Scenario.CloseGap2PeriodsCashToFloor) {
            return _ordinaryCashWeakStableRaw();
        }

        return _minCountedStableRaw();
    }

    function _assertScenario(
        Scenario scenario,
        StateSnapshot memory beforeState,
        StateSnapshot memory afterState,
        Vm.Log[] memory logs,
        CounterSnapshot memory snapshot
    ) internal view {
        ScenarioLogCapture memory capture = _collectLogCapture(logs);

        if (scenario == Scenario.NormalSwap) {
            _assertNormalSwap(capture.counts, snapshot);
            return;
        }

        if (scenario == Scenario.CloseOnePeriodNoTransition) {
            _assertCloseOnePeriodNoTransition(capture.counts, snapshot);
            return;
        }

        if (scenario == Scenario.CloseOnePeriodFloorToCash) {
            _assertCloseOnePeriodFloorToCash(capture.counts, snapshot);
            return;
        }

        if (scenario == Scenario.CloseOnePeriodCashToFloor) {
            _assertCloseOnePeriodCashToFloor(beforeState, afterState, capture, snapshot);
            return;
        }

        if (scenario == Scenario.CloseGap2PeriodsCashToFloor) {
            _assertCloseGap2PeriodsCashToFloor(beforeState, afterState, capture, snapshot);
            return;
        }

        if (scenario == Scenario.CloseEmergencyCashToFloor) {
            _assertCloseEmergencyCashToFloor(beforeState, afterState, capture, snapshot);
            return;
        }

        if (scenario == Scenario.IdleReset) {
            _assertIdleReset(capture.counts, snapshot);
            return;
        }

        if (
            scenario == Scenario.CloseGap2PeriodsNoTransition || scenario == Scenario.CloseGap8PeriodsNoTransition
                || scenario == Scenario.CloseGap23PeriodsNoTransition
        ) {
            _assertGapCloseNoTransition(capture.counts, snapshot, _scenarioPeriods(scenario));
            return;
        }

        if (scenario == Scenario.CloseGap2PeriodsWithFloorToCash) {
            _assertCloseGap2PeriodsWithFloorToCash(capture.counts, snapshot);
            return;
        }
    }

    function _assertNormalSwap(LogCounts memory counts, CounterSnapshot memory snapshot) internal view {
        (uint64 periodVolume,, uint64 periodStart, uint8 feeIdx) = hook.unpackedState();
        assertEq(counts.periodClosedCount, 0, "normal swap must not close a period");
        assertEq(counts.traceCount, 0, "normal swap must not emit close trace");
        assertEq(counts.idleResetCount, 0, "normal swap must not idle reset");
        assertEq(counts.feeUpdatedCount, 0, "normal swap must not change fee tier");
        assertEq(
            periodVolume,
            _minCountedUsd6() * 2,
            "normal swap baseline must stay in-period and append counted volume"
        );
        assertEq(feeIdx, hook.MODE_FLOOR(), "normal swap baseline stays in floor mode");
        assertGt(periodStart, 0, "normal swap must keep initialized period start");
        assertEq(manager.updateCount(), snapshot.updateBefore, "normal swap must not update LP fee");
    }

    function _assertCloseOnePeriodNoTransition(LogCounts memory counts, CounterSnapshot memory snapshot) internal view {
        (uint64 periodVolume,, uint64 periodStart, uint8 feeIdx) = hook.unpackedState();
        assertEq(counts.periodClosedCount, 1, "single close must close exactly one period");
        assertEq(counts.traceCount, 1, "single close must emit one close trace");
        assertEq(counts.idleResetCount, 0, "single close must not idle reset");
        assertEq(counts.feeUpdatedCount, 0, "single close baseline must not change fee tier");
        assertEq(periodVolume, _minCountedUsd6(), "single close must start a new counted open period");
        assertEq(feeIdx, hook.MODE_FLOOR(), "single close baseline stays in floor mode");
        assertGt(periodStart, 0, "single close must preserve initialized period start");
        assertEq(manager.updateCount(), snapshot.updateBefore, "single close baseline must not update LP fee");
    }

    function _assertCloseOnePeriodFloorToCash(LogCounts memory counts, CounterSnapshot memory snapshot)
        internal
        view
    {
        (uint64 periodVolume,, uint64 periodStart, uint8 feeIdx) = hook.unpackedState();
        assertEq(counts.periodClosedCount, 1, "transition close must close exactly one period");
        assertEq(counts.traceCount, 1, "transition close must emit one close trace");
        assertEq(counts.idleResetCount, 0, "transition close must not idle reset");
        assertEq(counts.feeUpdatedCount, 1, "transition close must emit one fee sync");
        assertEq(periodVolume, _minCountedUsd6(), "transition close must start a new counted open period");
        assertEq(feeIdx, hook.MODE_CASH(), "scenario must exercise FLOOR -> CASH");
        assertGt(periodStart, 0, "transition close must preserve initialized period start");
        assertEq(manager.updateCount(), snapshot.updateBefore + 1, "transition close must perform one LP fee update");
    }

    function _assertCloseOnePeriodCashToFloor(
        StateSnapshot memory beforeState,
        StateSnapshot memory afterState,
        ScenarioLogCapture memory capture,
        CounterSnapshot memory snapshot
    ) internal view {
        assertEq(beforeState.feeIdx, hook.MODE_CASH(), "ordinary immediate path must start in cash");
        assertEq(beforeState.holdRemaining, 0, "ordinary immediate path must start after hold is exhausted");
        assertEq(
            beforeState.downStreak,
            cfg.exitCashConfirmPeriods - 1,
            "ordinary immediate path must start one confirm short of cash->floor"
        );
        assertEq(beforeState.emergencyStreak, 0, "ordinary immediate path must not preload emergency reset");

        assertEq(capture.counts.periodClosedCount, 1, "ordinary immediate path must close exactly one elapsed period");
        assertEq(capture.counts.traceCount, 1, "ordinary immediate path must emit one close trace");
        assertEq(capture.counts.idleResetCount, 0, "ordinary immediate path must not idle reset");
        assertEq(capture.counts.feeUpdatedCount, 1, "ordinary immediate path must sync LP fee once");
        assertEq(capture.lastTrace.fromFeeIdx, hook.MODE_CASH(), "ordinary immediate path must start from cash");
        assertEq(capture.lastTrace.toFeeIdx, hook.MODE_FLOOR(), "ordinary immediate path must end at floor");
        assertEq(
            capture.lastTrace.reasonCode,
            hook.REASON_DOWN_TO_FLOOR(),
            "ordinary immediate path must use the normal cash->floor transition"
        );
        assertEq(
            capture.lastTrace.decisionBits & TRACE_FLAG_EMERGENCY_TRIGGERED,
            0,
            "ordinary immediate path must not use emergency reset"
        );
        assertEq(
            capture.lastPeriodClosed.reasonCode,
            hook.REASON_DOWN_TO_FLOOR(),
            "ordinary immediate close must report the normal downward reason"
        );

        assertEq(afterState.feeIdx, hook.MODE_FLOOR(), "ordinary immediate path must end in floor");
        assertEq(afterState.downStreak, 0, "ordinary immediate path must clear the down streak after transition");
        assertEq(afterState.emergencyStreak, 0, "ordinary immediate path must keep emergency reset inactive");
        assertEq(manager.updateCount(), snapshot.updateBefore + 1, "ordinary immediate path must perform one LP fee update");
    }

    function _assertCloseGap2PeriodsCashToFloor(
        StateSnapshot memory beforeState,
        StateSnapshot memory afterState,
        ScenarioLogCapture memory capture,
        CounterSnapshot memory snapshot
    ) internal view {
        assertEq(beforeState.feeIdx, hook.MODE_CASH(), "ordinary gap path must start in cash");
        assertEq(beforeState.holdRemaining, 0, "ordinary gap path must start after hold is exhausted");
        assertEq(
            beforeState.downStreak,
            cfg.exitCashConfirmPeriods - 2,
            "ordinary gap path must start two missed closes short of cash->floor"
        );
        assertEq(beforeState.emergencyStreak, 0, "ordinary gap path must not preload emergency reset");

        assertEq(
            capture.counts.periodClosedCount,
            GAP_2_PERIODS,
            "ordinary gap path must close the expected missed periods"
        );
        assertEq(
            capture.counts.traceCount,
            GAP_2_PERIODS,
            "ordinary gap path must emit one trace per missed close"
        );
        assertEq(capture.counts.idleResetCount, 0, "ordinary gap path must not idle reset");
        assertEq(capture.counts.feeUpdatedCount, 1, "ordinary gap path must sync LP fee once");
        assertEq(capture.lastTrace.fromFeeIdx, hook.MODE_CASH(), "ordinary gap path must start from cash");
        assertEq(capture.lastTrace.toFeeIdx, hook.MODE_FLOOR(), "ordinary gap path must end at floor");
        assertEq(
            capture.lastTrace.reasonCode,
            hook.REASON_DOWN_TO_FLOOR(),
            "ordinary gap path must end through the normal cash->floor transition"
        );
        assertEq(
            capture.lastTrace.decisionBits & TRACE_FLAG_EMERGENCY_TRIGGERED,
            0,
            "ordinary gap path must not use emergency reset"
        );
        assertEq(
            capture.lastPeriodClosed.reasonCode,
            hook.REASON_DOWN_TO_FLOOR(),
            "ordinary gap close must report the normal downward reason"
        );

        assertEq(afterState.feeIdx, hook.MODE_FLOOR(), "ordinary gap path must end in floor");
        assertEq(afterState.downStreak, 0, "ordinary gap path must clear the down streak after transition");
        assertLt(
            afterState.emergencyStreak,
            cfg.lowVolumeResetPeriods,
            "ordinary gap path must stay below the emergency reset threshold"
        );
        assertEq(manager.updateCount(), snapshot.updateBefore + 1, "ordinary gap path must perform one LP fee update");
    }

    function _assertCloseEmergencyCashToFloor(
        StateSnapshot memory beforeState,
        StateSnapshot memory afterState,
        ScenarioLogCapture memory capture,
        CounterSnapshot memory snapshot
    ) internal view {
        assertEq(beforeState.feeIdx, hook.MODE_CASH(), "emergency path must start in cash");
        assertGt(beforeState.holdRemaining, 0, "emergency path must still have ordinary hold active");
        assertEq(beforeState.downStreak, 0, "emergency path must not preload the ordinary down confirm");
        assertEq(
            beforeState.emergencyStreak,
            cfg.lowVolumeResetPeriods - 1,
            "emergency path must start one low-volume close short of reset"
        );

        assertEq(capture.counts.periodClosedCount, 1, "emergency path must close exactly one elapsed period");
        assertEq(capture.counts.traceCount, 1, "emergency path must emit one close trace");
        assertEq(capture.counts.idleResetCount, 0, "emergency path must not idle reset");
        assertEq(capture.counts.feeUpdatedCount, 1, "emergency path must sync LP fee once");
        assertEq(capture.lastTrace.fromFeeIdx, hook.MODE_CASH(), "emergency path must start from cash");
        assertEq(capture.lastTrace.toFeeIdx, hook.MODE_FLOOR(), "emergency path must end at floor");
        assertEq(
            capture.lastTrace.reasonCode,
            hook.REASON_EMERGENCY_FLOOR(),
            "emergency path must use the low-volume reset reason"
        );
        assertEq(
            capture.lastTrace.decisionBits & TRACE_FLAG_EMERGENCY_TRIGGERED,
            TRACE_FLAG_EMERGENCY_TRIGGERED,
            "emergency path must mark the emergency reset decision"
        );
        assertEq(
            capture.lastPeriodClosed.reasonCode,
            hook.REASON_EMERGENCY_FLOOR(),
            "emergency close must report the low-volume reset reason"
        );

        assertEq(afterState.feeIdx, hook.MODE_FLOOR(), "emergency path must end in floor");
        assertEq(afterState.holdRemaining, 0, "emergency reset must clear hold");
        assertEq(afterState.downStreak, 0, "emergency reset must clear the ordinary down streak");
        assertEq(afterState.emergencyStreak, 0, "emergency reset must clear the emergency streak");
        assertEq(manager.updateCount(), snapshot.updateBefore + 1, "emergency path must perform one LP fee update");
    }

    function _assertIdleReset(LogCounts memory counts, CounterSnapshot memory snapshot) internal view {
        (uint64 periodVolume, uint96 emaVolumeScaled,, uint8 feeIdx) = hook.unpackedState();
        assertEq(counts.periodClosedCount, 1, "idle reset must emit one closed-period record");
        assertEq(counts.traceCount, 1, "idle reset must emit one transition trace");
        assertEq(counts.idleResetCount, 1, "idle reset branch must emit idle reset");
        assertEq(counts.feeUpdatedCount, 1, "idle reset from cash must resync LP fee");
        assertEq(periodVolume, _minCountedUsd6(), "idle reset must count the current swap into the fresh period");
        assertEq(emaVolumeScaled, 0, "idle reset must clear EMA");
        assertEq(feeIdx, hook.MODE_FLOOR(), "idle reset must return to floor mode");
        assertEq(manager.updateCount(), snapshot.updateBefore + 1, "idle reset must perform one LP fee update");
    }

    function _assertGapCloseNoTransition(LogCounts memory counts, CounterSnapshot memory snapshot, uint64 expectedPeriods)
        internal
        view
    {
        (uint64 periodVolume,, uint64 periodStart, uint8 feeIdx) = hook.unpackedState();
        assertEq(counts.periodClosedCount, expectedPeriods, "gap close must close the expected number of periods");
        assertEq(counts.traceCount, expectedPeriods, "gap close must emit one trace per closed period");
        assertEq(counts.idleResetCount, 0, "gap close must stay below idle reset");
        assertEq(counts.feeUpdatedCount, 0, "pure gap close must avoid fee updates");
        assertEq(periodVolume, _minCountedUsd6(), "gap close must count the current swap into the fresh period");
        assertEq(feeIdx, hook.MODE_FLOOR(), "pure gap close must stay in floor mode");
        assertGt(periodStart, 0, "gap close must preserve initialized period start");
        assertEq(manager.updateCount(), snapshot.updateBefore, "pure gap close must not update LP fee");
    }

    function _assertCloseGap2PeriodsWithFloorToCash(LogCounts memory counts, CounterSnapshot memory snapshot)
        internal
        view
    {
        (uint64 periodVolume,, uint64 periodStart, uint8 feeIdx) = hook.unpackedState();
        assertEq(
            counts.periodClosedCount,
            GAP_2_PERIODS,
            "gap transition must close the expected number of periods"
        );
        assertEq(
            counts.traceCount,
            GAP_2_PERIODS,
            "gap transition must emit one trace per closed period"
        );
        assertEq(counts.idleResetCount, 0, "gap transition must stay below idle reset");
        assertEq(counts.feeUpdatedCount, 1, "gap transition must emit one fee sync");
        assertEq(periodVolume, _minCountedUsd6(), "gap transition must count the current swap into the fresh period");
        assertEq(feeIdx, hook.MODE_CASH(), "scenario must include a FLOOR -> CASH transition");
        assertGt(periodStart, 0, "gap transition must preserve initialized period start");
        assertEq(manager.updateCount(), snapshot.updateBefore + 1, "gap transition must perform one LP fee update");
    }

    function _collectLogCapture(Vm.Log[] memory logs) internal view returns (ScenarioLogCapture memory capture) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook) || logs[i].topics.length == 0) continue;

            bytes32 topic0 = logs[i].topics[0];
            if (topic0 == TRACE_SIG) {
                capture.counts.traceCount += 1;
                (
                    uint64 periodStart_,
                    uint24 fromFee_,
                    uint8 fromFeeIdx_,
                    uint24 toFee_,
                    uint8 toFeeIdx_,
                    uint64 periodVolume_,
                    uint96 emaVolumeBefore_,
                    uint96 emaVolumeAfter_,
                    uint64 approxLpFeesUsd_,
                    uint16 decisionBits_,
                    uint16 stateBitsBefore_,
                    uint16 stateBitsAfter_,
                    uint8 reasonCode_
                ) = abi.decode(
                    logs[i].data,
                    (uint64, uint24, uint8, uint24, uint8, uint64, uint96, uint96, uint64, uint16, uint16, uint16, uint8)
                );

                capture.lastTrace = ControllerTransitionTraceLog({
                    periodStart: periodStart_,
                    fromFee: fromFee_,
                    fromFeeIdx: fromFeeIdx_,
                    toFee: toFee_,
                    toFeeIdx: toFeeIdx_,
                    periodVolume: periodVolume_,
                    emaVolumeBefore: emaVolumeBefore_,
                    emaVolumeAfter: emaVolumeAfter_,
                    approxLpFeesUsd: approxLpFeesUsd_,
                    decisionBits: decisionBits_,
                    stateBitsBefore: stateBitsBefore_,
                    stateBitsAfter: stateBitsAfter_,
                    reasonCode: reasonCode_
                });
                continue;
            }

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
                continue;
            }

            if (topic0 == IDLE_RESET_SIG) {
                capture.counts.idleResetCount += 1;
                continue;
            }

            if (topic0 == FEE_UPDATED_SIG) {
                capture.counts.feeUpdatedCount += 1;
                continue;
            }
        }
    }

    function _scenarioPeriods(Scenario scenario) internal pure returns (uint64) {
        if (scenario == Scenario.CloseGap2PeriodsNoTransition) return GAP_2_PERIODS;
        if (scenario == Scenario.CloseGap8PeriodsNoTransition) return GAP_8_PERIODS;
        if (scenario == Scenario.CloseGap23PeriodsNoTransition) return GAP_23_PERIODS;
        return 0;
    }

    function _warpPeriods(uint64 periods) internal {
        vm.warp(block.timestamp + uint256(periods) * uint256(cfg.periodSeconds));
    }

    function _captureState() internal view returns (StateSnapshot memory state_) {
        (
            state_.feeIdx,
            state_.holdRemaining,
            state_.upExtremeStreak,
            state_.downStreak,
            state_.emergencyStreak,
            state_.periodStart,
            state_.periodVolume,
            state_.emaVolumeScaled,
            state_.paused
        ) = hook.getStateDebug();
    }
}
