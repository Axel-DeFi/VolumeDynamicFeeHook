// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {GasMeasurementLocalBase} from "../../local/foundry/GasMeasurementLocalBase.sol";
import {ConfigLoader} from "../../shared/lib/ConfigLoader.sol";
import {EnvLib} from "../../shared/lib/EnvLib.sol";
import {GasMeasurementLib} from "../../shared/lib/GasMeasurementLib.sol";
import {OpsTypes} from "../../shared/types/OpsTypes.sol";

contract MeasureGasLocalReportTest is Test, GasMeasurementLocalBase {
    enum Scenario {
        NormalSwap,
        CloseOnePeriodNoTransition,
        CloseOnePeriodFloorToCash,
        CloseOnePeriodCashToFloor,
        CloseOnePeriodCashToExtreme,
        CloseOnePeriodExtremeToCash,
        CloseEmergencyCashToFloor,
        CloseEmergencyExtremeToFloor,
        IdleReset,
        CloseOnePeriodCashHoldBlocksFloor,
        CloseOnePeriodExtremeHoldBlocksCash,
        CloseGap2PeriodsNoTransition,
        CloseGap8PeriodsNoTransition,
        CloseGapMaxPeriodsNoTransition,
        CloseGap2PeriodsWithFloorToCash,
        CloseGap2PeriodsWithCashToFloor,
        CloseGap2PeriodsWithCashToExtreme,
        CloseGap2PeriodsWithExtremeToCash,
        CloseGap2PeriodsWithEmergencyCashToFloor,
        CloseGap2PeriodsWithEmergencyExtremeToFloor,
        CloseOnePeriodNoSwapsNoTransition,
        CloseGap2PeriodsNoSwapsNoTransition,
        CloseGap2PeriodsCashHoldBlocksFloor,
        CloseGap2PeriodsExtremeHoldBlocksCash
    }

    struct LogCounts {
        uint256 periodClosedCount;
        uint256 traceCount;
        uint256 idleResetCount;
        uint256 feeUpdatedCount;
    }

    struct ReasonCounts {
        uint256 noSwaps;
        uint256 idleReset;
        uint256 emaBootstrap;
        uint256 jumpCash;
        uint256 jumpExtreme;
        uint256 downToCash;
        uint256 downToFloor;
        uint256 hold;
        uint256 emergencyFloor;
        uint256 noChange;
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
        ReasonCounts traceReasons;
        ReasonCounts periodClosedReasons;
        ControllerTransitionTraceLog firstTrace;
        ControllerTransitionTraceLog lastTrace;
        PeriodClosedLog firstPeriodClosed;
        PeriodClosedLog lastPeriodClosed;
        bool hasTrace;
        bool hasPeriodClosed;
    }

    uint64 internal constant GAP_2_PERIODS = 2;
    uint64 internal constant GAP_8_PERIODS = 8;

    uint16 internal constant TRACE_FLAG_HOLD_WAS_ACTIVE = 0x0004;
    uint16 internal constant TRACE_FLAG_EMERGENCY_TRIGGERED = 0x0008;
    uint16 internal constant TRACE_FLAG_EXTREME_EXIT_TRIGGER = 0x0040;
    uint16 internal constant TRACE_FLAG_CASH_EXIT_TRIGGER = 0x0080;

    bytes32 internal constant PERIOD_CLOSED_SIG =
        keccak256("PeriodClosed(uint24,uint8,uint24,uint8,uint64,uint96,uint64,uint8)");
    bytes32 internal constant TRACE_SIG = keccak256(
        "ControllerTransitionTrace(uint64,uint24,uint8,uint24,uint8,uint64,uint96,uint96,uint64,uint16,uint16,uint16,uint8)"
    );
    bytes32 internal constant IDLE_RESET_SIG = keccak256("IdleReset(uint24,uint8)");
    bytes32 internal constant FEE_UPDATED_SIG = keccak256("FeeUpdated(uint24,uint8,uint64,uint96)");

    function _loadMeasurementConfig() internal view override returns (OpsTypes.CoreConfig memory cfg) {
        if (EnvLib.hasKey("DEPLOY_PERIOD_SECONDS") && EnvLib.hasKey("DEPLOY_STABLE")) {
            return ConfigLoader.loadCoreConfig();
        }

        cfg.runtime = OpsTypes.Runtime.Local;
        cfg.privateKey = 1;
        cfg.tickSpacing = 10;
        cfg.stableDecimals = 6;
        cfg.floorFeePips = 400;
        cfg.cashFeePips = 2_500;
        cfg.extremeFeePips = 9_000;
        cfg.periodSeconds = 60;
        cfg.emaPeriods = 8;
        cfg.idleResetSeconds = 600;
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

    function testGas_close_one_period_cash_to_extreme() public {
        _runMeasuredScenario(Scenario.CloseOnePeriodCashToExtreme);
    }

    function testGas_close_one_period_extreme_to_cash() public {
        _runMeasuredScenario(Scenario.CloseOnePeriodExtremeToCash);
    }

    function testGas_close_emergency_cash_to_floor() public {
        _runMeasuredScenario(Scenario.CloseEmergencyCashToFloor);
    }

    function testGas_close_emergency_extreme_to_floor() public {
        _runMeasuredScenario(Scenario.CloseEmergencyExtremeToFloor);
    }

    function testGas_idle_reset() public {
        _runMeasuredScenario(Scenario.IdleReset);
    }

    function testGas_close_one_period_cash_hold_blocks_floor() public {
        _runMeasuredScenario(Scenario.CloseOnePeriodCashHoldBlocksFloor);
    }

    function testGas_close_one_period_extreme_hold_blocks_cash() public {
        _runMeasuredScenario(Scenario.CloseOnePeriodExtremeHoldBlocksCash);
    }

    function testGas_close_gap_2_periods_no_transition() public {
        _runMeasuredScenario(Scenario.CloseGap2PeriodsNoTransition);
    }

    function testGas_close_gap_8_periods_no_transition() public {
        _runMeasuredScenario(Scenario.CloseGap8PeriodsNoTransition);
    }

    function testGas_close_gap_max_periods_no_transition() public {
        _runMeasuredScenario(Scenario.CloseGapMaxPeriodsNoTransition);
    }

    function testGas_close_gap_2_periods_with_floor_to_cash() public {
        _runMeasuredScenario(Scenario.CloseGap2PeriodsWithFloorToCash);
    }

    function testGas_close_gap_2_periods_with_cash_to_floor() public {
        _runMeasuredScenario(Scenario.CloseGap2PeriodsWithCashToFloor);
    }

    function testGas_close_gap_2_periods_with_cash_to_extreme() public {
        _runMeasuredScenario(Scenario.CloseGap2PeriodsWithCashToExtreme);
    }

    function testGas_close_gap_2_periods_with_extreme_to_cash() public {
        _runMeasuredScenario(Scenario.CloseGap2PeriodsWithExtremeToCash);
    }

    function testGas_close_gap_2_periods_with_emergency_cash_to_floor() public {
        _runMeasuredScenario(Scenario.CloseGap2PeriodsWithEmergencyCashToFloor);
    }

    function testGas_close_gap_2_periods_with_emergency_extreme_to_floor() public {
        _runMeasuredScenario(Scenario.CloseGap2PeriodsWithEmergencyExtremeToFloor);
    }

    function testGas_close_one_period_no_swaps_no_transition() public {
        _runMeasuredScenario(Scenario.CloseOnePeriodNoSwapsNoTransition);
    }

    function testGas_close_gap_2_periods_no_swaps_no_transition() public {
        _runMeasuredScenario(Scenario.CloseGap2PeriodsNoSwapsNoTransition);
    }

    function testGas_close_gap_2_periods_cash_hold_blocks_floor() public {
        _runMeasuredScenario(Scenario.CloseGap2PeriodsCashHoldBlocksFloor);
    }

    function testGas_close_gap_2_periods_extreme_hold_blocks_cash() public {
        _runMeasuredScenario(Scenario.CloseGap2PeriodsExtremeHoldBlocksCash);
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
            // Keeps the existing single-close benchmark methodology: bootstrap close without a fee-tier change.
            _swapStable(_seedStableRaw());
            _warpPeriods(1);
            return;
        }

        if (scenario == Scenario.CloseOnePeriodFloorToCash) {
            // Measured call closes exactly one elapsed period and performs FLOOR -> CASH.
            _primeFloorToCash();
            _warpPeriods(1);
            return;
        }

        if (scenario == Scenario.CloseOnePeriodCashToFloor) {
            _setUpCloseOnePeriodCashToFloor();
            return;
        }

        if (scenario == Scenario.CloseOnePeriodCashToExtreme) {
            _setUpCloseOnePeriodCashToExtreme();
            return;
        }

        if (scenario == Scenario.CloseOnePeriodExtremeToCash) {
            _setUpCloseOnePeriodExtremeToCash();
            return;
        }

        if (scenario == Scenario.CloseEmergencyCashToFloor) {
            _setUpCloseEmergencyCashToFloor();
            return;
        }

        if (scenario == Scenario.CloseEmergencyExtremeToFloor) {
            _setUpCloseEmergencyExtremeToFloor();
            return;
        }

        if (scenario == Scenario.IdleReset) {
            _moveToCash();
            vm.warp(block.timestamp + uint256(cfg.idleResetSeconds) + 1);
            return;
        }

        if (scenario == Scenario.CloseOnePeriodCashHoldBlocksFloor) {
            _setUpCloseOnePeriodCashHoldBlocksFloor();
            return;
        }

        if (scenario == Scenario.CloseOnePeriodExtremeHoldBlocksCash) {
            _setUpCloseOnePeriodExtremeHoldBlocksCash();
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

        if (scenario == Scenario.CloseGapMaxPeriodsNoTransition) {
            _prepareGapClose(_maxGapPeriods());
            return;
        }

        if (scenario == Scenario.CloseGap2PeriodsWithFloorToCash) {
            _setUpCloseGap2PeriodsWithFloorToCash();
            return;
        }

        if (scenario == Scenario.CloseGap2PeriodsWithCashToFloor) {
            _setUpCloseGap2PeriodsWithCashToFloor();
            return;
        }

        if (scenario == Scenario.CloseGap2PeriodsWithCashToExtreme) {
            _setUpCloseGap2PeriodsWithCashToExtreme();
            return;
        }

        if (scenario == Scenario.CloseGap2PeriodsWithExtremeToCash) {
            _setUpCloseGap2PeriodsWithExtremeToCash();
            return;
        }

        if (scenario == Scenario.CloseGap2PeriodsWithEmergencyCashToFloor) {
            _setUpCloseGap2PeriodsWithEmergencyCashToFloor();
            return;
        }

        if (scenario == Scenario.CloseGap2PeriodsWithEmergencyExtremeToFloor) {
            _setUpCloseGap2PeriodsWithEmergencyExtremeToFloor();
            return;
        }

        if (scenario == Scenario.CloseOnePeriodNoSwapsNoTransition) {
            _prepareNoSwapsGapClose(1);
            return;
        }

        if (scenario == Scenario.CloseGap2PeriodsNoSwapsNoTransition) {
            _prepareNoSwapsGapClose(GAP_2_PERIODS);
            return;
        }

        if (scenario == Scenario.CloseGap2PeriodsCashHoldBlocksFloor) {
            _setUpCloseGap2PeriodsCashHoldBlocksFloor();
            return;
        }

        if (scenario == Scenario.CloseGap2PeriodsExtremeHoldBlocksCash) {
            _setUpCloseGap2PeriodsExtremeHoldBlocksCash();
            return;
        }
    }

    function _executeScenario(Scenario scenario) internal {
        _swapStable(_measuredSwapAmountStableRaw(scenario));
    }

    function _prepareGapClose(uint64 periods) internal {
        require(periods > 1, "gap periods too small");
        require(
            periods * uint64(cfg.periodSeconds) < uint64(cfg.idleResetSeconds), "gap close crosses idle reset"
        );

        _swapStable(_seedStableRaw());
        _warpPeriods(periods);
    }

    function _prepareNoSwapsGapClose(uint64 periods) internal {
        require(periods > 0, "no-swaps periods too small");
        require(
            periods * uint64(cfg.periodSeconds) < uint64(cfg.idleResetSeconds),
            "no-swaps gap crosses idle reset"
        );
        _warpPeriods(periods);
    }

    function _setUpCloseOnePeriodCashToFloor() internal {
        // Starts in CASH with hold already exhausted and one ordinary down confirm left for the measured close.
        _enterCashWithOrdinaryWeakOpenPeriod();
        _advanceCashOrdinaryWeakToState(_oneCloseTransitionTarget(cfg.exitCashConfirmPeriods));

        StateSnapshot memory preState = _captureState();
        assertEq(preState.feeIdx, hook.MODE_CASH(), "cash->floor setup must start in cash");
        assertEq(preState.holdRemaining, 0, "cash->floor setup must exhaust hold before the measured close");
        assertEq(
            preState.downStreak,
            _oneCloseTransitionTarget(cfg.exitCashConfirmPeriods),
            "cash->floor setup must be one ordinary close short of floor"
        );
        assertEq(preState.emergencyStreak, 0, "cash->floor setup must avoid emergency reset");

        _warpPeriods(1);
    }

    function _setUpCloseOnePeriodCashToExtreme() internal {
        // Starts in CASH with a strong open period and one remaining confirm for the measured CASH -> EXTREME close.
        _enterCashWithStrongExtremeOpenPeriod();
        _advanceCashStrongToExtremeState(_oneCloseTransitionTarget(cfg.enterExtremeConfirmPeriods));

        StateSnapshot memory preState = _captureState();
        assertEq(preState.feeIdx, hook.MODE_CASH(), "cash->extreme setup must start in cash");
        assertEq(
            preState.upExtremeStreak,
            _oneCloseTransitionTarget(cfg.enterExtremeConfirmPeriods),
            "cash->extreme setup must be one strong close short of extreme"
        );
        assertEq(preState.emergencyStreak, 0, "cash->extreme setup must avoid emergency reset");

        _warpPeriods(1);
    }

    function _setUpCloseOnePeriodExtremeToCash() internal {
        // Starts in EXTREME with hold already exhausted and one ordinary down confirm left for the measured close.
        _enterExtremeWithOrdinaryWeakOpenPeriod();
        _advanceExtremeOrdinaryWeakToState(_oneCloseTransitionTarget(cfg.exitExtremeConfirmPeriods));

        StateSnapshot memory preState = _captureState();
        assertEq(preState.feeIdx, hook.MODE_EXTREME(), "extreme->cash setup must start in extreme");
        assertEq(preState.holdRemaining, 0, "extreme->cash setup must exhaust hold before the measured close");
        assertEq(
            preState.downStreak,
            _oneCloseTransitionTarget(cfg.exitExtremeConfirmPeriods),
            "extreme->cash setup must be one ordinary close short of cash"
        );
        assertEq(preState.emergencyStreak, 0, "extreme->cash setup must avoid emergency reset");

        _warpPeriods(1);
    }

    function _setUpCloseEmergencyCashToFloor() internal {
        // Starts in CASH and the measured close completes the low-volume emergency streak without using ordinary descent.
        _enterCashWithEmergencyWeakOpenPeriod();
        _advanceCashEmergencyToStreak(_oneCloseTransitionTarget(cfg.lowVolumeResetPeriods));

        StateSnapshot memory preState = _captureState();
        assertEq(preState.feeIdx, hook.MODE_CASH(), "cash emergency setup must start in cash");
        assertEq(
            preState.emergencyStreak,
            _oneCloseTransitionTarget(cfg.lowVolumeResetPeriods),
            "cash emergency setup must be one low-volume close short of reset"
        );
        assertEq(preState.downStreak, 0, "cash emergency setup must not preload ordinary down confirms");

        _warpPeriods(1);
    }

    function _setUpCloseEmergencyExtremeToFloor() internal {
        // Starts in EXTREME and the measured close completes the low-volume emergency streak without using EXTREME -> CASH.
        _enterExtremeWithEmergencyWeakOpenPeriod();
        _advanceExtremeEmergencyToStreak(_oneCloseTransitionTarget(cfg.lowVolumeResetPeriods));

        StateSnapshot memory preState = _captureState();
        assertEq(preState.feeIdx, hook.MODE_EXTREME(), "extreme emergency setup must start in extreme");
        assertEq(
            preState.emergencyStreak,
            _oneCloseTransitionTarget(cfg.lowVolumeResetPeriods),
            "extreme emergency setup must be one low-volume close short of reset"
        );
        assertEq(preState.downStreak, 0, "extreme emergency setup must not preload EXTREME -> CASH confirms");

        _warpPeriods(1);
    }

    function _setUpCloseOnePeriodCashHoldBlocksFloor() internal {
        // Starts in CASH with ordinary downward conditions present, but measured close stays in CASH because hold is active.
        require(cfg.holdCashPeriods > 1, "cash hold-blocked path unreachable when holdCashPeriods <= 1");
        _enterCashWithOrdinaryWeakOpenPeriod();

        StateSnapshot memory preState = _captureState();
        assertEq(preState.feeIdx, hook.MODE_CASH(), "cash hold setup must start in cash");
        assertGt(
            preState.holdRemaining, 1, "cash hold setup must keep hold active through the measured close"
        );
        assertEq(
            preState.downStreak, 0, "cash hold setup must start before ordinary down confirms accumulate"
        );

        _warpPeriods(1);
    }

    function _setUpCloseOnePeriodExtremeHoldBlocksCash() internal {
        // Starts in EXTREME with ordinary downward conditions present, but measured close stays in EXTREME because hold is active.
        require(
            cfg.holdExtremePeriods > 1, "extreme hold-blocked path unreachable when holdExtremePeriods <= 1"
        );
        _enterExtremeWithOrdinaryWeakOpenPeriod();

        StateSnapshot memory preState = _captureState();
        assertEq(preState.feeIdx, hook.MODE_EXTREME(), "extreme hold setup must start in extreme");
        assertGt(
            preState.holdRemaining, 1, "extreme hold setup must keep hold active through the measured close"
        );
        assertEq(
            preState.downStreak, 0, "extreme hold setup must start before ordinary down confirms accumulate"
        );

        _warpPeriods(1);
    }

    function _setUpCloseGap2PeriodsWithFloorToCash() internal {
        // Starts in FLOOR with a qualifying open period so the measured 2-period gap close includes FLOOR -> CASH.
        _primeFloorToCash();
        _warpPeriods(GAP_2_PERIODS);
    }

    function _setUpCloseGap2PeriodsWithCashToFloor() internal {
        // Starts in CASH, hold is already exhausted before the gap, and the 2-period gap close ends with ordinary CASH -> FLOOR.
        _enterCashWithOrdinaryWeakOpenPeriod();
        _advanceCashOrdinaryWeakToState(_gapDownTransitionTarget(cfg.exitCashConfirmPeriods));

        StateSnapshot memory preGapState = _captureState();
        assertEq(preGapState.feeIdx, hook.MODE_CASH(), "gap cash->floor setup must start in cash");
        assertEq(preGapState.holdRemaining, 0, "gap cash->floor setup must exhaust hold before the gap");
        assertEq(
            preGapState.downStreak,
            _gapDownTransitionTarget(cfg.exitCashConfirmPeriods),
            "gap cash->floor setup must leave the remaining confirms for the measured gap close"
        );
        assertEq(preGapState.emergencyStreak, 0, "gap cash->floor setup must avoid emergency reset");

        _warpPeriods(GAP_2_PERIODS);
    }

    function _setUpCloseGap2PeriodsWithCashToExtreme() internal {
        // Starts in CASH with one strong confirm remaining so the measured gap close includes CASH -> EXTREME.
        _enterCashWithStrongExtremeOpenPeriod();
        _advanceCashStrongToExtremeState(_oneCloseTransitionTarget(cfg.enterExtremeConfirmPeriods));

        StateSnapshot memory preGapState = _captureState();
        assertEq(preGapState.feeIdx, hook.MODE_CASH(), "gap cash->extreme setup must start in cash");
        assertEq(
            preGapState.upExtremeStreak,
            _oneCloseTransitionTarget(cfg.enterExtremeConfirmPeriods),
            "gap cash->extreme setup must leave the final strong confirm for the first missed close"
        );
        assertEq(preGapState.emergencyStreak, 0, "gap cash->extreme setup must avoid emergency reset");

        _warpPeriods(GAP_2_PERIODS);
    }

    function _setUpCloseGap2PeriodsWithExtremeToCash() internal {
        // Starts in EXTREME, hold is already exhausted before the gap, and the 2-period gap close ends with EXTREME -> CASH.
        _enterExtremeWithOrdinaryWeakOpenPeriod();
        _advanceExtremeOrdinaryWeakToState(_oneCloseTransitionTarget(cfg.exitExtremeConfirmPeriods));

        StateSnapshot memory preGapState = _captureState();
        assertEq(preGapState.feeIdx, hook.MODE_EXTREME(), "gap extreme->cash setup must start in extreme");
        assertEq(preGapState.holdRemaining, 0, "gap extreme->cash setup must exhaust hold before the gap");
        assertEq(
            preGapState.downStreak,
            _oneCloseTransitionTarget(cfg.exitExtremeConfirmPeriods),
            "gap extreme->cash setup must leave the final confirm to the first missed close"
        );
        assertEq(preGapState.emergencyStreak, 0, "gap extreme->cash setup must avoid emergency reset");

        _warpPeriods(GAP_2_PERIODS);
    }

    function _setUpCloseGap2PeriodsWithEmergencyCashToFloor() internal {
        // Starts in CASH and the 2-period gap close completes the low-volume emergency streak without using ordinary descent.
        _enterCashWithEmergencyWeakOpenPeriod();
        _advanceCashEmergencyToStreak(_gapEmergencyTransitionTarget(cfg.lowVolumeResetPeriods));

        StateSnapshot memory preGapState = _captureState();
        assertEq(preGapState.feeIdx, hook.MODE_CASH(), "gap cash emergency setup must start in cash");
        assertEq(
            preGapState.emergencyStreak,
            _gapEmergencyTransitionTarget(cfg.lowVolumeResetPeriods),
            "gap cash emergency setup must leave the emergency completion to the measured gap close"
        );
        assertEq(
            preGapState.downStreak, 0, "gap cash emergency setup must not preload ordinary down confirms"
        );

        _warpPeriods(GAP_2_PERIODS);
    }

    function _setUpCloseGap2PeriodsWithEmergencyExtremeToFloor() internal {
        // Starts in EXTREME and the 2-period gap close completes the low-volume emergency streak without using EXTREME -> CASH.
        _enterExtremeWithEmergencyWeakOpenPeriod();
        _advanceExtremeEmergencyToStreak(_gapEmergencyTransitionTarget(cfg.lowVolumeResetPeriods));

        StateSnapshot memory preGapState = _captureState();
        assertEq(preGapState.feeIdx, hook.MODE_EXTREME(), "gap extreme emergency setup must start in extreme");
        assertEq(
            preGapState.emergencyStreak,
            _gapEmergencyTransitionTarget(cfg.lowVolumeResetPeriods),
            "gap extreme emergency setup must leave the emergency completion to the measured gap close"
        );
        assertEq(
            preGapState.downStreak, 0, "gap extreme emergency setup must not preload EXTREME -> CASH confirms"
        );

        _warpPeriods(GAP_2_PERIODS);
    }

    function _setUpCloseGap2PeriodsCashHoldBlocksFloor() internal {
        // Starts in CASH with ordinary downward trigger conditions present, but the measured 2-period gap stays in CASH because hold blocks the path.
        require(cfg.holdCashPeriods > 1, "cash hold gap unreachable when holdCashPeriods <= 1");
        _enterCashWithOrdinaryWeakOpenPeriod();
        _warpPeriods(GAP_2_PERIODS);
    }

    function _setUpCloseGap2PeriodsExtremeHoldBlocksCash() internal {
        // Starts in EXTREME with ordinary downward trigger conditions present, but the measured 2-period gap stays in EXTREME because hold blocks the path.
        require(cfg.holdExtremePeriods > 1, "extreme hold gap unreachable when holdExtremePeriods <= 1");
        _enterExtremeWithOrdinaryWeakOpenPeriod();
        _warpPeriods(GAP_2_PERIODS);
    }

    function _enterCashWithOrdinaryWeakOpenPeriod() internal {
        _primeFloorToCash();
        _completeFloorToCash(_chooseNextDownOpenPeriodUsd6(cfg.exitCashEmaRatioPct));
        _assertMode(hook.MODE_CASH());
    }

    function _enterCashWithStrongExtremeOpenPeriod() internal {
        _primeFloorToCash();
        _completeFloorToCash(
            _chooseNextUpOpenPeriodUsd6(cfg.enterExtremeEmaRatioPct, cfg.enterExtremeMinVolume)
        );
        _assertMode(hook.MODE_CASH());
    }

    function _enterCashWithEmergencyWeakOpenPeriod() internal {
        _primeFloorToCash();
        _completeFloorToCash(_minCountedUsd6());
        _assertMode(hook.MODE_CASH());
    }

    function _enterExtremeWithOrdinaryWeakOpenPeriod() internal {
        _primeCashToExtreme();
        _completeCashToExtreme(_chooseNextDownOpenPeriodUsd6(cfg.exitExtremeEmaRatioPct));
        _assertMode(hook.MODE_EXTREME());
    }

    function _enterExtremeWithEmergencyWeakOpenPeriod() internal {
        _primeCashToExtreme();
        _completeCashToExtreme(_minCountedUsd6());
        _assertMode(hook.MODE_EXTREME());
    }

    function _advanceCashOrdinaryWeakClose() internal {
        _warpPeriods(1);
        _swapStable(_ordinaryCashWeakStableRaw());
        _assertMode(hook.MODE_CASH());
    }

    function _advanceCashStrongExtremeClose() internal {
        _warpPeriods(1);
        _swapStable(_strongExtremeStableRaw());
        _assertMode(hook.MODE_CASH());
    }

    function _advanceCashEmergencyClose() internal {
        _warpPeriods(1);
        _swapStable(_minCountedStableRaw());
        _assertMode(hook.MODE_CASH());
    }

    function _advanceExtremeOrdinaryWeakClose() internal {
        _warpPeriods(1);
        _swapStable(_ordinaryExtremeWeakStableRaw());
        _assertMode(hook.MODE_EXTREME());
    }

    function _advanceExtremeEmergencyClose() internal {
        _warpPeriods(1);
        _swapStable(_minCountedStableRaw());
        _assertMode(hook.MODE_EXTREME());
    }

    function _advanceCashOrdinaryWeakToState(uint8 targetDownStreak) internal {
        for (uint256 i = 0; i < 64; ++i) {
            StateSnapshot memory state = _captureState();
            if (
                state.feeIdx == hook.MODE_CASH() && state.holdRemaining == 0
                    && state.downStreak == targetDownStreak && state.emergencyStreak == 0
            ) {
                return;
            }

            _advanceCashOrdinaryWeakClose();
        }

        revert("cash ordinary weak setup did not converge");
    }

    function _advanceCashStrongToExtremeState(uint8 targetUpExtremeStreak) internal {
        for (uint256 i = 0; i < 64; ++i) {
            StateSnapshot memory state = _captureState();
            if (
                state.feeIdx == hook.MODE_CASH() && state.upExtremeStreak == targetUpExtremeStreak
                    && state.emergencyStreak == 0
            ) {
                return;
            }

            _advanceCashStrongExtremeClose();
        }

        revert("cash strong setup did not converge");
    }

    function _advanceCashEmergencyToStreak(uint8 targetEmergencyStreak) internal {
        for (uint256 i = 0; i < 64; ++i) {
            StateSnapshot memory state = _captureState();
            if (
                state.feeIdx == hook.MODE_CASH() && state.emergencyStreak == targetEmergencyStreak
                    && state.downStreak == 0
            ) {
                return;
            }

            _advanceCashEmergencyClose();
        }

        revert("cash emergency setup did not converge");
    }

    function _advanceExtremeOrdinaryWeakToState(uint8 targetDownStreak) internal {
        for (uint256 i = 0; i < 64; ++i) {
            StateSnapshot memory state = _captureState();
            if (
                state.feeIdx == hook.MODE_EXTREME() && state.holdRemaining == 0
                    && state.downStreak == targetDownStreak && state.emergencyStreak == 0
            ) {
                return;
            }

            _advanceExtremeOrdinaryWeakClose();
        }

        revert("extreme ordinary weak setup did not converge");
    }

    function _advanceExtremeEmergencyToStreak(uint8 targetEmergencyStreak) internal {
        for (uint256 i = 0; i < 64; ++i) {
            StateSnapshot memory state = _captureState();
            if (
                state.feeIdx == hook.MODE_EXTREME() && state.emergencyStreak == targetEmergencyStreak
                    && state.downStreak == 0
            ) {
                return;
            }

            _advanceExtremeEmergencyClose();
        }

        revert("extreme emergency setup did not converge");
    }

    function _ordinaryCashWeakStableRaw() internal view returns (uint256) {
        return GasMeasurementLib.usd6ToStableRaw(
            _chooseNextDownOpenPeriodUsd6(cfg.exitCashEmaRatioPct), cfg.stableDecimals
        );
    }

    function _ordinaryExtremeWeakStableRaw() internal view returns (uint256) {
        return GasMeasurementLib.usd6ToStableRaw(
            _chooseNextDownOpenPeriodUsd6(cfg.exitExtremeEmaRatioPct), cfg.stableDecimals
        );
    }

    function _strongExtremeStableRaw() internal view returns (uint256) {
        return GasMeasurementLib.usd6ToStableRaw(
            _chooseNextUpOpenPeriodUsd6(cfg.enterExtremeEmaRatioPct, cfg.enterExtremeMinVolume),
            cfg.stableDecimals
        );
    }

    function _measuredSwapAmountStableRaw(Scenario scenario) internal view returns (uint256) {
        if (
            scenario == Scenario.CloseOnePeriodCashToFloor
                || scenario == Scenario.CloseGap2PeriodsWithCashToFloor
                || scenario == Scenario.CloseOnePeriodCashHoldBlocksFloor
                || scenario == Scenario.CloseGap2PeriodsCashHoldBlocksFloor
        ) {
            return _ordinaryCashWeakStableRaw();
        }

        if (
            scenario == Scenario.CloseOnePeriodExtremeToCash
                || scenario == Scenario.CloseGap2PeriodsWithExtremeToCash
                || scenario == Scenario.CloseOnePeriodExtremeHoldBlocksCash
                || scenario == Scenario.CloseGap2PeriodsExtremeHoldBlocksCash
        ) {
            return _ordinaryExtremeWeakStableRaw();
        }

        if (
            scenario == Scenario.CloseOnePeriodCashToExtreme
                || scenario == Scenario.CloseGap2PeriodsWithCashToExtreme
        ) {
            return _strongExtremeStableRaw();
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
        _assertReasonTalliesAligned(capture);

        if (scenario == Scenario.NormalSwap) {
            _assertNormalSwap(capture.counts, snapshot);
            return;
        }

        if (scenario == Scenario.CloseOnePeriodNoTransition) {
            _assertCloseOnePeriodNoTransition(beforeState, afterState, capture, snapshot);
            return;
        }

        if (scenario == Scenario.CloseOnePeriodFloorToCash) {
            _assertCloseOnePeriodFloorToCash(beforeState, afterState, capture, snapshot);
            return;
        }

        if (scenario == Scenario.CloseOnePeriodCashToFloor) {
            _assertCloseOnePeriodCashToFloor(beforeState, afterState, capture, snapshot);
            return;
        }

        if (scenario == Scenario.CloseOnePeriodCashToExtreme) {
            _assertCloseOnePeriodCashToExtreme(beforeState, afterState, capture, snapshot);
            return;
        }

        if (scenario == Scenario.CloseOnePeriodExtremeToCash) {
            _assertCloseOnePeriodExtremeToCash(beforeState, afterState, capture, snapshot);
            return;
        }

        if (scenario == Scenario.CloseEmergencyCashToFloor) {
            _assertCloseEmergencyCashToFloor(beforeState, afterState, capture, snapshot);
            return;
        }

        if (scenario == Scenario.CloseEmergencyExtremeToFloor) {
            _assertCloseEmergencyExtremeToFloor(beforeState, afterState, capture, snapshot);
            return;
        }

        if (scenario == Scenario.IdleReset) {
            _assertIdleReset(beforeState, afterState, capture, snapshot);
            return;
        }

        if (scenario == Scenario.CloseOnePeriodCashHoldBlocksFloor) {
            _assertCloseOnePeriodCashHoldBlocksFloor(beforeState, afterState, capture, snapshot);
            return;
        }

        if (scenario == Scenario.CloseOnePeriodExtremeHoldBlocksCash) {
            _assertCloseOnePeriodExtremeHoldBlocksCash(beforeState, afterState, capture, snapshot);
            return;
        }

        if (
            scenario == Scenario.CloseGap2PeriodsNoTransition
                || scenario == Scenario.CloseGap8PeriodsNoTransition
                || scenario == Scenario.CloseGapMaxPeriodsNoTransition
        ) {
            _assertGapCloseNoTransition(
                beforeState, afterState, capture, snapshot, _scenarioPeriods(scenario)
            );
            return;
        }

        if (scenario == Scenario.CloseGap2PeriodsWithFloorToCash) {
            _assertCloseGap2PeriodsWithFloorToCash(beforeState, afterState, capture, snapshot);
            return;
        }

        if (scenario == Scenario.CloseGap2PeriodsWithCashToFloor) {
            _assertCloseGap2PeriodsWithCashToFloor(beforeState, afterState, capture, snapshot);
            return;
        }

        if (scenario == Scenario.CloseGap2PeriodsWithCashToExtreme) {
            _assertCloseGap2PeriodsWithCashToExtreme(beforeState, afterState, capture, snapshot);
            return;
        }

        if (scenario == Scenario.CloseGap2PeriodsWithExtremeToCash) {
            _assertCloseGap2PeriodsWithExtremeToCash(beforeState, afterState, capture, snapshot);
            return;
        }

        if (scenario == Scenario.CloseGap2PeriodsWithEmergencyCashToFloor) {
            _assertCloseGap2PeriodsWithEmergencyCashToFloor(beforeState, afterState, capture, snapshot);
            return;
        }

        if (scenario == Scenario.CloseGap2PeriodsWithEmergencyExtremeToFloor) {
            _assertCloseGap2PeriodsWithEmergencyExtremeToFloor(beforeState, afterState, capture, snapshot);
            return;
        }

        if (scenario == Scenario.CloseOnePeriodNoSwapsNoTransition) {
            _assertCloseOnePeriodNoSwapsNoTransition(beforeState, afterState, capture, snapshot);
            return;
        }

        if (scenario == Scenario.CloseGap2PeriodsNoSwapsNoTransition) {
            _assertCloseGap2PeriodsNoSwapsNoTransition(beforeState, afterState, capture, snapshot);
            return;
        }

        if (scenario == Scenario.CloseGap2PeriodsCashHoldBlocksFloor) {
            _assertCloseGap2PeriodsCashHoldBlocksFloor(beforeState, afterState, capture, snapshot);
            return;
        }

        _assertCloseGap2PeriodsExtremeHoldBlocksCash(beforeState, afterState, capture, snapshot);
    }

    function _assertNormalSwap(LogCounts memory counts, CounterSnapshot memory snapshot) internal view {
        (uint64 periodVolume,, uint64 periodStart, uint8 feeIdx) = hook.unpackedState();
        assertEq(counts.periodClosedCount, 0, "normal swap must not close a period");
        assertEq(counts.traceCount, 0, "normal swap must not emit a transition trace");
        assertEq(counts.idleResetCount, 0, "normal swap must not idle reset");
        assertEq(counts.feeUpdatedCount, 0, "normal swap must not update LP fee");
        assertEq(periodVolume, _minCountedUsd6() * 2, "normal swap must append volume inside the open period");
        assertEq(feeIdx, hook.MODE_FLOOR(), "normal swap baseline must stay in floor");
        assertGt(periodStart, 0, "normal swap must keep an initialized period start");
        assertEq(manager.updateCount(), snapshot.updateBefore, "normal swap must not change LP fee");
    }

    function _assertCloseOnePeriodNoTransition(
        StateSnapshot memory beforeState,
        StateSnapshot memory afterState,
        ScenarioLogCapture memory capture,
        CounterSnapshot memory snapshot
    ) internal view {
        assertEq(beforeState.feeIdx, hook.MODE_FLOOR(), "single close baseline must start in floor");
        assertEq(beforeState.emaVolumeScaled, 0, "single close baseline must start before EMA bootstrap");
        assertEq(beforeState.periodVolume, _seedUsd6(), "single close baseline must close the seeded period");

        assertEq(capture.counts.periodClosedCount, 1, "single close must close exactly one elapsed period");
        assertEq(capture.counts.traceCount, 1, "single close must emit one trace");
        assertEq(capture.counts.idleResetCount, 0, "single close must not idle reset");
        assertEq(capture.counts.feeUpdatedCount, 0, "single close must not update LP fee");
        assertEq(
            capture.traceReasons.emaBootstrap, 1, "single close baseline must exercise the EMA bootstrap path"
        );
        assertEq(capture.traceReasons.jumpCash, 0, "single close baseline must not transition up");
        assertEq(capture.traceReasons.downToFloor, 0, "single close baseline must not transition down");

        assertEq(afterState.feeIdx, hook.MODE_FLOOR(), "single close baseline must stay in floor");
        assertEq(
            afterState.periodVolume, _minCountedUsd6(), "single close must start a fresh counted open period"
        );
        assertEq(manager.updateCount(), snapshot.updateBefore, "single close must not change LP fee");
    }

    function _assertCloseOnePeriodFloorToCash(
        StateSnapshot memory beforeState,
        StateSnapshot memory afterState,
        ScenarioLogCapture memory capture,
        CounterSnapshot memory snapshot
    ) internal view {
        assertEq(beforeState.feeIdx, hook.MODE_FLOOR(), "floor->cash path must start in floor");

        assertEq(
            capture.counts.periodClosedCount, 1, "floor->cash path must close exactly one elapsed period"
        );
        assertEq(capture.counts.traceCount, 1, "floor->cash path must emit one trace");
        assertEq(capture.counts.idleResetCount, 0, "floor->cash path must not idle reset");
        assertEq(capture.counts.feeUpdatedCount, 1, "floor->cash path must sync LP fee once");
        assertEq(capture.traceReasons.jumpCash, 1, "floor->cash path must use the ordinary upward transition");
        assertEq(capture.traceReasons.emergencyFloor, 0, "floor->cash path must not use emergency reset");
        assertEq(capture.lastTrace.fromFeeIdx, hook.MODE_FLOOR(), "floor->cash path must start from floor");
        assertEq(capture.lastTrace.toFeeIdx, hook.MODE_CASH(), "floor->cash path must end at cash");

        assertEq(afterState.feeIdx, hook.MODE_CASH(), "floor->cash path must end in cash");
        assertEq(manager.updateCount(), snapshot.updateBefore + 1, "floor->cash path must change LP fee once");
    }

    function _assertCloseOnePeriodCashToFloor(
        StateSnapshot memory beforeState,
        StateSnapshot memory afterState,
        ScenarioLogCapture memory capture,
        CounterSnapshot memory snapshot
    ) internal view {
        assertEq(beforeState.feeIdx, hook.MODE_CASH(), "cash->floor path must start in cash");
        assertEq(beforeState.holdRemaining, 0, "cash->floor path must start after hold exhaustion");
        assertEq(
            beforeState.downStreak,
            _oneCloseTransitionTarget(cfg.exitCashConfirmPeriods),
            "cash->floor path must start one confirm short of floor"
        );
        assertEq(beforeState.emergencyStreak, 0, "cash->floor path must not preload emergency reset");

        assertEq(
            capture.counts.periodClosedCount, 1, "cash->floor path must close exactly one elapsed period"
        );
        assertEq(capture.counts.traceCount, 1, "cash->floor path must emit one trace");
        assertEq(capture.counts.idleResetCount, 0, "cash->floor path must not idle reset");
        assertEq(capture.counts.feeUpdatedCount, 1, "cash->floor path must sync LP fee once");
        assertEq(
            capture.traceReasons.downToFloor, 1, "cash->floor path must use the ordinary downward transition"
        );
        assertEq(capture.traceReasons.emergencyFloor, 0, "cash->floor path must not use emergency reset");
        assertEq(capture.lastTrace.fromFeeIdx, hook.MODE_CASH(), "cash->floor path must start from cash");
        assertEq(capture.lastTrace.toFeeIdx, hook.MODE_FLOOR(), "cash->floor path must end at floor");
        assertEq(
            capture.lastTrace.decisionBits & TRACE_FLAG_EMERGENCY_TRIGGERED,
            0,
            "cash->floor path must not mark the emergency branch"
        );

        assertEq(afterState.feeIdx, hook.MODE_FLOOR(), "cash->floor path must end in floor");
        assertEq(afterState.downStreak, 0, "cash->floor path must clear the down streak after transition");
        assertEq(afterState.emergencyStreak, 0, "cash->floor path must keep emergency reset inactive");
        assertEq(manager.updateCount(), snapshot.updateBefore + 1, "cash->floor path must change LP fee once");
    }

    function _assertCloseOnePeriodCashToExtreme(
        StateSnapshot memory beforeState,
        StateSnapshot memory afterState,
        ScenarioLogCapture memory capture,
        CounterSnapshot memory snapshot
    ) internal view {
        assertEq(beforeState.feeIdx, hook.MODE_CASH(), "cash->extreme path must start in cash");
        assertEq(
            beforeState.upExtremeStreak,
            _oneCloseTransitionTarget(cfg.enterExtremeConfirmPeriods),
            "cash->extreme path must start one strong close short of extreme"
        );
        assertEq(beforeState.emergencyStreak, 0, "cash->extreme path must not preload emergency reset");

        assertEq(
            capture.counts.periodClosedCount, 1, "cash->extreme path must close exactly one elapsed period"
        );
        assertEq(capture.counts.traceCount, 1, "cash->extreme path must emit one trace");
        assertEq(capture.counts.idleResetCount, 0, "cash->extreme path must not idle reset");
        assertEq(capture.counts.feeUpdatedCount, 1, "cash->extreme path must sync LP fee once");
        assertEq(
            capture.traceReasons.jumpExtreme, 1, "cash->extreme path must use the ordinary upward transition"
        );
        assertEq(capture.traceReasons.emergencyFloor, 0, "cash->extreme path must not use emergency reset");
        assertEq(capture.lastTrace.fromFeeIdx, hook.MODE_CASH(), "cash->extreme path must start from cash");
        assertEq(capture.lastTrace.toFeeIdx, hook.MODE_EXTREME(), "cash->extreme path must end at extreme");

        assertEq(afterState.feeIdx, hook.MODE_EXTREME(), "cash->extreme path must end in extreme");
        assertEq(afterState.downStreak, 0, "cash->extreme path must reset the down streak");
        assertEq(
            afterState.upExtremeStreak,
            0,
            "cash->extreme path must clear the extreme up streak after transition"
        );
        assertEq(
            manager.updateCount(), snapshot.updateBefore + 1, "cash->extreme path must change LP fee once"
        );
    }

    function _assertCloseOnePeriodExtremeToCash(
        StateSnapshot memory beforeState,
        StateSnapshot memory afterState,
        ScenarioLogCapture memory capture,
        CounterSnapshot memory snapshot
    ) internal view {
        assertEq(beforeState.feeIdx, hook.MODE_EXTREME(), "extreme->cash path must start in extreme");
        assertEq(beforeState.holdRemaining, 0, "extreme->cash path must start after hold exhaustion");
        assertEq(
            beforeState.downStreak,
            _oneCloseTransitionTarget(cfg.exitExtremeConfirmPeriods),
            "extreme->cash path must start one confirm short of cash"
        );
        assertEq(beforeState.emergencyStreak, 0, "extreme->cash path must not preload emergency reset");

        assertEq(
            capture.counts.periodClosedCount, 1, "extreme->cash path must close exactly one elapsed period"
        );
        assertEq(capture.counts.traceCount, 1, "extreme->cash path must emit one trace");
        assertEq(capture.counts.idleResetCount, 0, "extreme->cash path must not idle reset");
        assertEq(capture.counts.feeUpdatedCount, 1, "extreme->cash path must sync LP fee once");
        assertEq(
            capture.traceReasons.downToCash, 1, "extreme->cash path must use the ordinary downward transition"
        );
        assertEq(capture.traceReasons.emergencyFloor, 0, "extreme->cash path must not use emergency reset");
        assertEq(
            capture.lastTrace.fromFeeIdx, hook.MODE_EXTREME(), "extreme->cash path must start from extreme"
        );
        assertEq(capture.lastTrace.toFeeIdx, hook.MODE_CASH(), "extreme->cash path must end at cash");

        assertEq(afterState.feeIdx, hook.MODE_CASH(), "extreme->cash path must end in cash");
        assertEq(afterState.downStreak, 0, "extreme->cash path must clear the down streak after transition");
        assertEq(afterState.emergencyStreak, 0, "extreme->cash path must keep emergency reset inactive");
        assertEq(
            manager.updateCount(), snapshot.updateBefore + 1, "extreme->cash path must change LP fee once"
        );
    }

    function _assertCloseEmergencyCashToFloor(
        StateSnapshot memory beforeState,
        StateSnapshot memory afterState,
        ScenarioLogCapture memory capture,
        CounterSnapshot memory snapshot
    ) internal view {
        assertEq(beforeState.feeIdx, hook.MODE_CASH(), "cash emergency path must start in cash");
        assertEq(
            beforeState.emergencyStreak,
            _oneCloseTransitionTarget(cfg.lowVolumeResetPeriods),
            "cash emergency path must start one low-volume close short of reset"
        );
        assertEq(beforeState.downStreak, 0, "cash emergency path must not preload ordinary down confirms");

        assertEq(
            capture.counts.periodClosedCount, 1, "cash emergency path must close exactly one elapsed period"
        );
        assertEq(capture.counts.traceCount, 1, "cash emergency path must emit one trace");
        assertEq(capture.counts.idleResetCount, 0, "cash emergency path must not idle reset");
        assertEq(capture.counts.feeUpdatedCount, 1, "cash emergency path must sync LP fee once");
        assertEq(
            capture.traceReasons.emergencyFloor, 1, "cash emergency path must use the emergency reset branch"
        );
        assertEq(capture.traceReasons.downToFloor, 0, "cash emergency path must not use ordinary cash->floor");
        assertEq(capture.lastTrace.fromFeeIdx, hook.MODE_CASH(), "cash emergency path must start from cash");
        assertEq(capture.lastTrace.toFeeIdx, hook.MODE_FLOOR(), "cash emergency path must end at floor");
        assertEq(
            capture.lastTrace.decisionBits & TRACE_FLAG_EMERGENCY_TRIGGERED,
            TRACE_FLAG_EMERGENCY_TRIGGERED,
            "cash emergency path must mark the emergency branch"
        );

        assertEq(afterState.feeIdx, hook.MODE_FLOOR(), "cash emergency path must end in floor");
        assertEq(afterState.holdRemaining, 0, "cash emergency path must clear hold");
        assertEq(afterState.downStreak, 0, "cash emergency path must clear the down streak");
        assertEq(afterState.emergencyStreak, 0, "cash emergency path must clear the emergency streak");
        assertEq(
            manager.updateCount(), snapshot.updateBefore + 1, "cash emergency path must change LP fee once"
        );
    }

    function _assertCloseEmergencyExtremeToFloor(
        StateSnapshot memory beforeState,
        StateSnapshot memory afterState,
        ScenarioLogCapture memory capture,
        CounterSnapshot memory snapshot
    ) internal view {
        assertEq(beforeState.feeIdx, hook.MODE_EXTREME(), "extreme emergency path must start in extreme");
        assertEq(
            beforeState.emergencyStreak,
            _oneCloseTransitionTarget(cfg.lowVolumeResetPeriods),
            "extreme emergency path must start one low-volume close short of reset"
        );
        assertEq(
            beforeState.downStreak, 0, "extreme emergency path must not preload EXTREME -> CASH confirms"
        );

        assertEq(
            capture.counts.periodClosedCount,
            1,
            "extreme emergency path must close exactly one elapsed period"
        );
        assertEq(capture.counts.traceCount, 1, "extreme emergency path must emit one trace");
        assertEq(capture.counts.idleResetCount, 0, "extreme emergency path must not idle reset");
        assertEq(capture.counts.feeUpdatedCount, 1, "extreme emergency path must sync LP fee once");
        assertEq(
            capture.traceReasons.emergencyFloor,
            1,
            "extreme emergency path must use the emergency reset branch"
        );
        assertEq(capture.traceReasons.downToCash, 0, "extreme emergency path must not use EXTREME -> CASH");
        assertEq(
            capture.lastTrace.fromFeeIdx,
            hook.MODE_EXTREME(),
            "extreme emergency path must start from extreme"
        );
        assertEq(capture.lastTrace.toFeeIdx, hook.MODE_FLOOR(), "extreme emergency path must end at floor");
        assertEq(
            capture.lastTrace.decisionBits & TRACE_FLAG_EMERGENCY_TRIGGERED,
            TRACE_FLAG_EMERGENCY_TRIGGERED,
            "extreme emergency path must mark the emergency branch"
        );

        assertEq(afterState.feeIdx, hook.MODE_FLOOR(), "extreme emergency path must end in floor");
        assertEq(afterState.holdRemaining, 0, "extreme emergency path must clear hold");
        assertEq(afterState.downStreak, 0, "extreme emergency path must clear the down streak");
        assertEq(afterState.emergencyStreak, 0, "extreme emergency path must clear the emergency streak");
        assertEq(
            manager.updateCount(), snapshot.updateBefore + 1, "extreme emergency path must change LP fee once"
        );
    }

    function _assertIdleReset(
        StateSnapshot memory beforeState,
        StateSnapshot memory afterState,
        ScenarioLogCapture memory capture,
        CounterSnapshot memory snapshot
    ) internal view {
        assertEq(beforeState.feeIdx, hook.MODE_CASH(), "idle reset path must start in cash");

        assertEq(capture.counts.periodClosedCount, 1, "idle reset must emit one closed-period record");
        assertEq(capture.counts.traceCount, 1, "idle reset must emit one transition trace");
        assertEq(capture.counts.idleResetCount, 1, "idle reset must emit IdleReset");
        assertEq(capture.counts.feeUpdatedCount, 1, "idle reset from cash must sync LP fee once");
        assertEq(capture.traceReasons.idleReset, 1, "idle reset path must report the idle-reset reason");

        assertEq(afterState.feeIdx, hook.MODE_FLOOR(), "idle reset must return to floor");
        assertEq(afterState.emaVolumeScaled, 0, "idle reset must clear EMA");
        assertEq(
            afterState.periodVolume,
            _minCountedUsd6(),
            "idle reset must count the current swap into the fresh period"
        );
        assertEq(manager.updateCount(), snapshot.updateBefore + 1, "idle reset must change LP fee once");
    }

    function _assertCloseOnePeriodCashHoldBlocksFloor(
        StateSnapshot memory beforeState,
        StateSnapshot memory afterState,
        ScenarioLogCapture memory capture,
        CounterSnapshot memory snapshot
    ) internal view {
        assertEq(beforeState.feeIdx, hook.MODE_CASH(), "cash hold path must start in cash");
        assertGt(
            beforeState.holdRemaining, 1, "cash hold path must keep hold active through the measured close"
        );
        assertEq(beforeState.downStreak, 0, "cash hold path must start before down confirms");

        assertEq(capture.counts.periodClosedCount, 1, "cash hold path must close exactly one elapsed period");
        assertEq(capture.counts.traceCount, 1, "cash hold path must emit one trace");
        assertEq(capture.counts.idleResetCount, 0, "cash hold path must not idle reset");
        assertEq(capture.counts.feeUpdatedCount, 0, "cash hold path must not change LP fee");
        assertEq(capture.traceReasons.hold, 1, "cash hold path must use the hold-blocked reason");
        assertEq(capture.traceReasons.downToFloor, 0, "cash hold path must not descend to floor");
        assertEq(capture.traceReasons.emergencyFloor, 0, "cash hold path must not use emergency reset");
        assertEq(capture.lastTrace.fromFeeIdx, hook.MODE_CASH(), "cash hold path must start from cash");
        assertEq(capture.lastTrace.toFeeIdx, hook.MODE_CASH(), "cash hold path must stay in cash");
        assertEq(
            capture.lastTrace.decisionBits & TRACE_FLAG_HOLD_WAS_ACTIVE,
            TRACE_FLAG_HOLD_WAS_ACTIVE,
            "cash hold path must record that hold was active"
        );
        assertEq(
            capture.lastTrace.decisionBits & TRACE_FLAG_CASH_EXIT_TRIGGER,
            TRACE_FLAG_CASH_EXIT_TRIGGER,
            "cash hold path must still see the ordinary cash exit trigger"
        );

        assertEq(afterState.feeIdx, hook.MODE_CASH(), "cash hold path must stay in cash");
        assertEq(
            afterState.holdRemaining, beforeState.holdRemaining - 1, "cash hold path must decrement hold once"
        );
        assertEq(afterState.downStreak, 0, "cash hold path must keep the down streak blocked");
        assertEq(manager.updateCount(), snapshot.updateBefore, "cash hold path must not change LP fee");
    }

    function _assertCloseOnePeriodExtremeHoldBlocksCash(
        StateSnapshot memory beforeState,
        StateSnapshot memory afterState,
        ScenarioLogCapture memory capture,
        CounterSnapshot memory snapshot
    ) internal view {
        assertEq(beforeState.feeIdx, hook.MODE_EXTREME(), "extreme hold path must start in extreme");
        assertGt(
            beforeState.holdRemaining, 1, "extreme hold path must keep hold active through the measured close"
        );
        assertEq(beforeState.downStreak, 0, "extreme hold path must start before down confirms");

        assertEq(
            capture.counts.periodClosedCount, 1, "extreme hold path must close exactly one elapsed period"
        );
        assertEq(capture.counts.traceCount, 1, "extreme hold path must emit one trace");
        assertEq(capture.counts.idleResetCount, 0, "extreme hold path must not idle reset");
        assertEq(capture.counts.feeUpdatedCount, 0, "extreme hold path must not change LP fee");
        assertEq(capture.traceReasons.hold, 1, "extreme hold path must use the hold-blocked reason");
        assertEq(capture.traceReasons.downToCash, 0, "extreme hold path must not descend to cash");
        assertEq(capture.traceReasons.emergencyFloor, 0, "extreme hold path must not use emergency reset");
        assertEq(
            capture.lastTrace.fromFeeIdx, hook.MODE_EXTREME(), "extreme hold path must start from extreme"
        );
        assertEq(capture.lastTrace.toFeeIdx, hook.MODE_EXTREME(), "extreme hold path must stay in extreme");
        assertEq(
            capture.lastTrace.decisionBits & TRACE_FLAG_HOLD_WAS_ACTIVE,
            TRACE_FLAG_HOLD_WAS_ACTIVE,
            "extreme hold path must record that hold was active"
        );
        assertEq(
            capture.lastTrace.decisionBits & TRACE_FLAG_EXTREME_EXIT_TRIGGER,
            TRACE_FLAG_EXTREME_EXIT_TRIGGER,
            "extreme hold path must still see the ordinary extreme exit trigger"
        );

        assertEq(afterState.feeIdx, hook.MODE_EXTREME(), "extreme hold path must stay in extreme");
        assertEq(
            afterState.holdRemaining,
            beforeState.holdRemaining - 1,
            "extreme hold path must decrement hold once"
        );
        assertEq(afterState.downStreak, 0, "extreme hold path must keep the down streak blocked");
        assertEq(manager.updateCount(), snapshot.updateBefore, "extreme hold path must not change LP fee");
    }

    function _assertGapCloseNoTransition(
        StateSnapshot memory beforeState,
        StateSnapshot memory afterState,
        ScenarioLogCapture memory capture,
        CounterSnapshot memory snapshot,
        uint64 expectedPeriods
    ) internal view {
        assertEq(beforeState.feeIdx, hook.MODE_FLOOR(), "gap no-transition path must start in floor");
        assertEq(
            beforeState.periodVolume,
            _seedUsd6(),
            "gap no-transition path must start from the seeded open period"
        );

        assertEq(
            capture.counts.periodClosedCount,
            expectedPeriods,
            "gap no-transition path must close the expected periods"
        );
        assertEq(
            capture.counts.traceCount,
            expectedPeriods,
            "gap no-transition path must emit one trace per closed period"
        );
        assertEq(capture.counts.idleResetCount, 0, "gap no-transition path must stay below idle reset");
        assertEq(capture.counts.feeUpdatedCount, 0, "gap no-transition path must not change LP fee");
        assertEq(
            capture.traceReasons.emaBootstrap,
            1,
            "gap no-transition path must bootstrap EMA on the first close"
        );
        assertEq(
            capture.traceReasons.noSwaps,
            expectedPeriods - 1,
            "gap no-transition path must use no-swaps for each additional missed period"
        );
        assertEq(capture.traceReasons.jumpCash, 0, "gap no-transition path must not transition up");
        assertEq(capture.traceReasons.downToFloor, 0, "gap no-transition path must not transition down");
        assertEq(
            capture.traceReasons.emergencyFloor, 0, "gap no-transition path must not use emergency reset"
        );

        assertEq(afterState.feeIdx, hook.MODE_FLOOR(), "gap no-transition path must stay in floor");
        assertEq(
            afterState.periodVolume,
            _minCountedUsd6(),
            "gap no-transition path must start a fresh counted open period"
        );
        assertEq(
            manager.updateCount(), snapshot.updateBefore, "gap no-transition path must not change LP fee"
        );
    }

    function _assertCloseGap2PeriodsWithFloorToCash(
        StateSnapshot memory beforeState,
        StateSnapshot memory afterState,
        ScenarioLogCapture memory capture,
        CounterSnapshot memory snapshot
    ) internal view {
        assertEq(beforeState.feeIdx, hook.MODE_FLOOR(), "gap floor->cash path must start in floor");

        assertEq(
            capture.counts.periodClosedCount,
            GAP_2_PERIODS,
            "gap floor->cash path must close two missed periods"
        );
        assertEq(capture.counts.traceCount, GAP_2_PERIODS, "gap floor->cash path must emit two traces");
        assertEq(capture.counts.idleResetCount, 0, "gap floor->cash path must not idle reset");
        assertEq(capture.counts.feeUpdatedCount, 1, "gap floor->cash path must sync LP fee once");
        assertEq(
            capture.traceReasons.jumpCash, 1, "gap floor->cash path must include one FLOOR -> CASH transition"
        );
        assertEq(
            capture.traceReasons.hold,
            1,
            "gap floor->cash path must process one held CASH period inside the gap"
        );
        assertEq(capture.traceReasons.emergencyFloor, 0, "gap floor->cash path must not use emergency reset");
        assertEq(
            capture.firstTrace.fromFeeIdx, hook.MODE_FLOOR(), "gap floor->cash path must start from floor"
        );
        assertEq(
            capture.firstTrace.toFeeIdx,
            hook.MODE_CASH(),
            "gap floor->cash path must enter cash on the gap close"
        );
        assertEq(
            capture.lastTrace.reasonCode,
            hook.REASON_HOLD(),
            "gap floor->cash path must end with the held CASH close"
        );

        assertEq(afterState.feeIdx, hook.MODE_CASH(), "gap floor->cash path must end in cash");
        assertEq(
            manager.updateCount(), snapshot.updateBefore + 1, "gap floor->cash path must change LP fee once"
        );
    }

    function _assertCloseGap2PeriodsWithCashToFloor(
        StateSnapshot memory beforeState,
        StateSnapshot memory afterState,
        ScenarioLogCapture memory capture,
        CounterSnapshot memory snapshot
    ) internal view {
        assertEq(beforeState.feeIdx, hook.MODE_CASH(), "gap cash->floor path must start in cash");
        assertEq(beforeState.holdRemaining, 0, "gap cash->floor path must start after hold exhaustion");
        assertEq(
            beforeState.downStreak,
            _gapDownTransitionTarget(cfg.exitCashConfirmPeriods),
            "gap cash->floor path must leave the remaining confirms to the measured gap close"
        );

        assertEq(
            capture.counts.periodClosedCount,
            GAP_2_PERIODS,
            "gap cash->floor path must close two missed periods"
        );
        assertEq(capture.counts.traceCount, GAP_2_PERIODS, "gap cash->floor path must emit two traces");
        assertEq(capture.counts.idleResetCount, 0, "gap cash->floor path must not idle reset");
        assertEq(capture.counts.feeUpdatedCount, 1, "gap cash->floor path must sync LP fee once");
        assertEq(
            capture.traceReasons.noChange,
            1,
            "gap cash->floor path must use one ordinary weak close before descending"
        );
        assertEq(
            capture.traceReasons.downToFloor, 1, "gap cash->floor path must descend to floor inside the gap"
        );
        assertEq(capture.traceReasons.emergencyFloor, 0, "gap cash->floor path must not use emergency reset");
        assertEq(
            capture.lastTrace.reasonCode,
            hook.REASON_DOWN_TO_FLOOR(),
            "gap cash->floor path must end with cash->floor"
        );

        assertEq(afterState.feeIdx, hook.MODE_FLOOR(), "gap cash->floor path must end in floor");
        assertEq(afterState.downStreak, 0, "gap cash->floor path must clear the down streak after transition");
        assertEq(
            manager.updateCount(), snapshot.updateBefore + 1, "gap cash->floor path must change LP fee once"
        );
    }

    function _assertCloseGap2PeriodsWithCashToExtreme(
        StateSnapshot memory beforeState,
        StateSnapshot memory afterState,
        ScenarioLogCapture memory capture,
        CounterSnapshot memory snapshot
    ) internal view {
        assertEq(beforeState.feeIdx, hook.MODE_CASH(), "gap cash->extreme path must start in cash");
        assertEq(
            beforeState.upExtremeStreak,
            _oneCloseTransitionTarget(cfg.enterExtremeConfirmPeriods),
            "gap cash->extreme path must leave the final strong confirm to the first missed close"
        );

        assertEq(
            capture.counts.periodClosedCount,
            GAP_2_PERIODS,
            "gap cash->extreme path must close two missed periods"
        );
        assertEq(capture.counts.traceCount, GAP_2_PERIODS, "gap cash->extreme path must emit two traces");
        assertEq(capture.counts.idleResetCount, 0, "gap cash->extreme path must not idle reset");
        assertEq(capture.counts.feeUpdatedCount, 1, "gap cash->extreme path must sync LP fee once");
        assertEq(
            capture.traceReasons.jumpExtreme,
            1,
            "gap cash->extreme path must include one CASH -> EXTREME transition"
        );
        assertEq(
            capture.traceReasons.hold,
            1,
            "gap cash->extreme path must process one held EXTREME period inside the gap"
        );
        assertEq(
            capture.traceReasons.emergencyFloor, 0, "gap cash->extreme path must not use emergency reset"
        );
        assertEq(
            capture.firstTrace.fromFeeIdx, hook.MODE_CASH(), "gap cash->extreme path must start from cash"
        );
        assertEq(
            capture.firstTrace.toFeeIdx,
            hook.MODE_EXTREME(),
            "gap cash->extreme path must enter extreme inside the gap"
        );
        assertEq(
            capture.lastTrace.reasonCode,
            hook.REASON_HOLD(),
            "gap cash->extreme path must end with the held EXTREME close"
        );

        assertEq(afterState.feeIdx, hook.MODE_EXTREME(), "gap cash->extreme path must end in extreme");
        assertEq(
            manager.updateCount(), snapshot.updateBefore + 1, "gap cash->extreme path must change LP fee once"
        );
    }

    function _assertCloseGap2PeriodsWithExtremeToCash(
        StateSnapshot memory beforeState,
        StateSnapshot memory afterState,
        ScenarioLogCapture memory capture,
        CounterSnapshot memory snapshot
    ) internal view {
        assertEq(beforeState.feeIdx, hook.MODE_EXTREME(), "gap extreme->cash path must start in extreme");
        assertEq(beforeState.holdRemaining, 0, "gap extreme->cash path must start after hold exhaustion");
        assertEq(
            beforeState.downStreak,
            _oneCloseTransitionTarget(cfg.exitExtremeConfirmPeriods),
            "gap extreme->cash path must leave the final confirm to the first missed close"
        );

        assertEq(
            capture.counts.periodClosedCount,
            GAP_2_PERIODS,
            "gap extreme->cash path must close two missed periods"
        );
        assertEq(capture.counts.traceCount, GAP_2_PERIODS, "gap extreme->cash path must emit two traces");
        assertEq(capture.counts.idleResetCount, 0, "gap extreme->cash path must not idle reset");
        assertEq(capture.counts.feeUpdatedCount, 1, "gap extreme->cash path must sync LP fee once");
        assertEq(
            capture.traceReasons.downToCash, 1, "gap extreme->cash path must descend to cash inside the gap"
        );
        assertEq(
            capture.traceReasons.emergencyFloor, 0, "gap extreme->cash path must not use emergency reset"
        );
        assertEq(
            capture.firstTrace.reasonCode,
            hook.REASON_DOWN_TO_CASH(),
            "gap extreme->cash path must descend on the first missed close"
        );

        assertEq(afterState.feeIdx, hook.MODE_CASH(), "gap extreme->cash path must end in cash");
        assertLt(
            afterState.downStreak,
            cfg.exitCashConfirmPeriods,
            "gap extreme->cash path must stay below cash->floor transition"
        );
        assertEq(
            manager.updateCount(), snapshot.updateBefore + 1, "gap extreme->cash path must change LP fee once"
        );
    }

    function _assertCloseGap2PeriodsWithEmergencyCashToFloor(
        StateSnapshot memory beforeState,
        StateSnapshot memory afterState,
        ScenarioLogCapture memory capture,
        CounterSnapshot memory snapshot
    ) internal view {
        assertEq(beforeState.feeIdx, hook.MODE_CASH(), "gap cash emergency path must start in cash");
        assertEq(
            beforeState.emergencyStreak,
            _gapEmergencyTransitionTarget(cfg.lowVolumeResetPeriods),
            "gap cash emergency path must leave the emergency completion to the measured gap close"
        );
        assertEq(beforeState.downStreak, 0, "gap cash emergency path must not preload ordinary down confirms");

        assertEq(
            capture.counts.periodClosedCount,
            GAP_2_PERIODS,
            "gap cash emergency path must close two missed periods"
        );
        assertEq(capture.counts.traceCount, GAP_2_PERIODS, "gap cash emergency path must emit two traces");
        assertEq(capture.counts.idleResetCount, 0, "gap cash emergency path must not idle reset");
        assertEq(capture.counts.feeUpdatedCount, 1, "gap cash emergency path must sync LP fee once");
        assertEq(
            capture.traceReasons.emergencyFloor,
            1,
            "gap cash emergency path must use emergency reset inside the gap"
        );
        assertEq(
            capture.traceReasons.downToFloor, 0, "gap cash emergency path must not use ordinary cash->floor"
        );
        assertEq(
            capture.lastTrace.reasonCode,
            hook.REASON_EMERGENCY_FLOOR(),
            "gap cash emergency path must end with emergency"
        );

        assertEq(afterState.feeIdx, hook.MODE_FLOOR(), "gap cash emergency path must end in floor");
        assertEq(afterState.holdRemaining, 0, "gap cash emergency path must clear hold");
        assertEq(afterState.downStreak, 0, "gap cash emergency path must clear the down streak");
        assertEq(afterState.emergencyStreak, 0, "gap cash emergency path must clear the emergency streak");
        assertEq(
            manager.updateCount(),
            snapshot.updateBefore + 1,
            "gap cash emergency path must change LP fee once"
        );
    }

    function _assertCloseGap2PeriodsWithEmergencyExtremeToFloor(
        StateSnapshot memory beforeState,
        StateSnapshot memory afterState,
        ScenarioLogCapture memory capture,
        CounterSnapshot memory snapshot
    ) internal view {
        assertEq(beforeState.feeIdx, hook.MODE_EXTREME(), "gap extreme emergency path must start in extreme");
        assertEq(
            beforeState.emergencyStreak,
            _gapEmergencyTransitionTarget(cfg.lowVolumeResetPeriods),
            "gap extreme emergency path must leave the emergency completion to the measured gap close"
        );
        assertEq(
            beforeState.downStreak, 0, "gap extreme emergency path must not preload EXTREME -> CASH confirms"
        );

        assertEq(
            capture.counts.periodClosedCount,
            GAP_2_PERIODS,
            "gap extreme emergency path must close two missed periods"
        );
        assertEq(capture.counts.traceCount, GAP_2_PERIODS, "gap extreme emergency path must emit two traces");
        assertEq(capture.counts.idleResetCount, 0, "gap extreme emergency path must not idle reset");
        assertEq(capture.counts.feeUpdatedCount, 1, "gap extreme emergency path must sync LP fee once");
        assertEq(
            capture.traceReasons.emergencyFloor,
            1,
            "gap extreme emergency path must use emergency reset inside the gap"
        );
        assertEq(
            capture.traceReasons.downToCash, 0, "gap extreme emergency path must not use EXTREME -> CASH"
        );
        assertEq(
            capture.lastTrace.reasonCode,
            hook.REASON_EMERGENCY_FLOOR(),
            "gap extreme emergency path must end with emergency"
        );

        assertEq(afterState.feeIdx, hook.MODE_FLOOR(), "gap extreme emergency path must end in floor");
        assertEq(afterState.holdRemaining, 0, "gap extreme emergency path must clear hold");
        assertEq(afterState.downStreak, 0, "gap extreme emergency path must clear the down streak");
        assertEq(afterState.emergencyStreak, 0, "gap extreme emergency path must clear the emergency streak");
        assertEq(
            manager.updateCount(),
            snapshot.updateBefore + 1,
            "gap extreme emergency path must change LP fee once"
        );
    }

    function _assertCloseOnePeriodNoSwapsNoTransition(
        StateSnapshot memory beforeState,
        StateSnapshot memory afterState,
        ScenarioLogCapture memory capture,
        CounterSnapshot memory snapshot
    ) internal view {
        assertEq(beforeState.feeIdx, hook.MODE_FLOOR(), "no-swaps path must start in floor");
        assertEq(beforeState.periodVolume, 0, "no-swaps path must start from an empty open period");
        assertEq(beforeState.emaVolumeScaled, 0, "no-swaps path must start before EMA bootstrap");

        assertEq(capture.counts.periodClosedCount, 1, "no-swaps path must close exactly one elapsed period");
        assertEq(capture.counts.traceCount, 1, "no-swaps path must emit one trace");
        assertEq(capture.counts.idleResetCount, 0, "no-swaps path must not idle reset");
        assertEq(capture.counts.feeUpdatedCount, 0, "no-swaps path must not change LP fee");
        assertEq(capture.traceReasons.noSwaps, 1, "no-swaps path must use the no-swaps reason");
        assertEq(capture.traceReasons.emergencyFloor, 0, "no-swaps path must not use emergency reset");

        assertEq(afterState.feeIdx, hook.MODE_FLOOR(), "no-swaps path must stay in floor");
        assertEq(afterState.emaVolumeScaled, 0, "no-swaps path must keep EMA at zero");
        assertEq(
            afterState.periodVolume,
            _minCountedUsd6(),
            "no-swaps path must count the current swap into the fresh period"
        );
        assertEq(manager.updateCount(), snapshot.updateBefore, "no-swaps path must not change LP fee");
    }

    function _assertCloseGap2PeriodsNoSwapsNoTransition(
        StateSnapshot memory beforeState,
        StateSnapshot memory afterState,
        ScenarioLogCapture memory capture,
        CounterSnapshot memory snapshot
    ) internal view {
        assertEq(beforeState.feeIdx, hook.MODE_FLOOR(), "gap no-swaps path must start in floor");
        assertEq(beforeState.periodVolume, 0, "gap no-swaps path must start from an empty open period");
        assertEq(beforeState.emaVolumeScaled, 0, "gap no-swaps path must start before EMA bootstrap");

        assertEq(
            capture.counts.periodClosedCount, GAP_2_PERIODS, "gap no-swaps path must close two missed periods"
        );
        assertEq(capture.counts.traceCount, GAP_2_PERIODS, "gap no-swaps path must emit two traces");
        assertEq(capture.counts.idleResetCount, 0, "gap no-swaps path must not idle reset");
        assertEq(capture.counts.feeUpdatedCount, 0, "gap no-swaps path must not change LP fee");
        assertEq(
            capture.traceReasons.noSwaps,
            GAP_2_PERIODS,
            "gap no-swaps path must use no-swaps for both missed periods"
        );
        assertEq(capture.traceReasons.emergencyFloor, 0, "gap no-swaps path must not use emergency reset");

        assertEq(afterState.feeIdx, hook.MODE_FLOOR(), "gap no-swaps path must stay in floor");
        assertEq(afterState.emaVolumeScaled, 0, "gap no-swaps path must keep EMA at zero");
        assertEq(
            afterState.periodVolume,
            _minCountedUsd6(),
            "gap no-swaps path must count the current swap into the fresh period"
        );
        assertEq(manager.updateCount(), snapshot.updateBefore, "gap no-swaps path must not change LP fee");
    }

    function _assertCloseGap2PeriodsCashHoldBlocksFloor(
        StateSnapshot memory beforeState,
        StateSnapshot memory afterState,
        ScenarioLogCapture memory capture,
        CounterSnapshot memory snapshot
    ) internal view {
        assertEq(beforeState.feeIdx, hook.MODE_CASH(), "gap cash hold path must start in cash");
        assertGt(beforeState.holdRemaining, 1, "gap cash hold path must start with hold active");

        assertEq(
            capture.counts.periodClosedCount,
            GAP_2_PERIODS,
            "gap cash hold path must close two missed periods"
        );
        assertEq(capture.counts.traceCount, GAP_2_PERIODS, "gap cash hold path must emit two traces");
        assertEq(capture.counts.idleResetCount, 0, "gap cash hold path must not idle reset");
        assertEq(capture.counts.feeUpdatedCount, 0, "gap cash hold path must not change LP fee");
        assertGe(capture.traceReasons.hold, 1, "gap cash hold path must include a hold-blocked close");
        assertEq(capture.traceReasons.downToFloor, 0, "gap cash hold path must not descend to floor");
        assertEq(capture.traceReasons.emergencyFloor, 0, "gap cash hold path must not use emergency reset");
        assertEq(
            capture.firstTrace.reasonCode,
            hook.REASON_HOLD(),
            "gap cash hold path must start with a held CASH close"
        );
        assertEq(
            capture.firstTrace.decisionBits & TRACE_FLAG_CASH_EXIT_TRIGGER,
            TRACE_FLAG_CASH_EXIT_TRIGGER,
            "gap cash hold path must still see the ordinary cash exit trigger"
        );

        assertEq(afterState.feeIdx, hook.MODE_CASH(), "gap cash hold path must stay in cash");
        assertEq(manager.updateCount(), snapshot.updateBefore, "gap cash hold path must not change LP fee");
    }

    function _assertCloseGap2PeriodsExtremeHoldBlocksCash(
        StateSnapshot memory beforeState,
        StateSnapshot memory afterState,
        ScenarioLogCapture memory capture,
        CounterSnapshot memory snapshot
    ) internal view {
        assertEq(beforeState.feeIdx, hook.MODE_EXTREME(), "gap extreme hold path must start in extreme");
        assertGt(beforeState.holdRemaining, 1, "gap extreme hold path must start with hold active");

        assertEq(
            capture.counts.periodClosedCount,
            GAP_2_PERIODS,
            "gap extreme hold path must close two missed periods"
        );
        assertEq(capture.counts.traceCount, GAP_2_PERIODS, "gap extreme hold path must emit two traces");
        assertEq(capture.counts.idleResetCount, 0, "gap extreme hold path must not idle reset");
        assertEq(capture.counts.feeUpdatedCount, 0, "gap extreme hold path must not change LP fee");
        assertGe(capture.traceReasons.hold, 1, "gap extreme hold path must include a hold-blocked close");
        assertEq(capture.traceReasons.downToCash, 0, "gap extreme hold path must not descend to cash");
        assertEq(capture.traceReasons.emergencyFloor, 0, "gap extreme hold path must not use emergency reset");
        assertEq(
            capture.firstTrace.reasonCode,
            hook.REASON_HOLD(),
            "gap extreme hold path must start with a held EXTREME close"
        );
        assertEq(
            capture.firstTrace.decisionBits & TRACE_FLAG_EXTREME_EXIT_TRIGGER,
            TRACE_FLAG_EXTREME_EXIT_TRIGGER,
            "gap extreme hold path must still see the ordinary extreme exit trigger"
        );

        assertEq(afterState.feeIdx, hook.MODE_EXTREME(), "gap extreme hold path must stay in extreme");
        assertEq(manager.updateCount(), snapshot.updateBefore, "gap extreme hold path must not change LP fee");
    }

    function _collectLogCapture(Vm.Log[] memory logs)
        internal
        view
        returns (ScenarioLogCapture memory capture)
    {
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
                    (
                        uint64,
                        uint24,
                        uint8,
                        uint24,
                        uint8,
                        uint64,
                        uint96,
                        uint96,
                        uint64,
                        uint16,
                        uint16,
                        uint16,
                        uint8
                    )
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
                if (!capture.hasTrace) {
                    capture.firstTrace = capture.lastTrace;
                    capture.hasTrace = true;
                }
                capture.traceReasons = _incrementReasonCounts(capture.traceReasons, reasonCode_);
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
                if (!capture.hasPeriodClosed) {
                    capture.firstPeriodClosed = capture.lastPeriodClosed;
                    capture.hasPeriodClosed = true;
                }
                capture.periodClosedReasons = _incrementReasonCounts(capture.periodClosedReasons, reasonCode_);
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

    function _incrementReasonCounts(ReasonCounts memory counts, uint8 reasonCode)
        internal
        view
        returns (ReasonCounts memory)
    {
        if (reasonCode == hook.REASON_NO_SWAPS()) counts.noSwaps += 1;
        else if (reasonCode == hook.REASON_IDLE_RESET()) counts.idleReset += 1;
        else if (reasonCode == hook.REASON_EMA_BOOTSTRAP()) counts.emaBootstrap += 1;
        else if (reasonCode == hook.REASON_JUMP_CASH()) counts.jumpCash += 1;
        else if (reasonCode == hook.REASON_JUMP_EXTREME()) counts.jumpExtreme += 1;
        else if (reasonCode == hook.REASON_DOWN_TO_CASH()) counts.downToCash += 1;
        else if (reasonCode == hook.REASON_DOWN_TO_FLOOR()) counts.downToFloor += 1;
        else if (reasonCode == hook.REASON_HOLD()) counts.hold += 1;
        else if (reasonCode == hook.REASON_EMERGENCY_FLOOR()) counts.emergencyFloor += 1;
        else if (reasonCode == hook.REASON_NO_CHANGE()) counts.noChange += 1;
        return counts;
    }

    function _assertReasonTalliesAligned(ScenarioLogCapture memory capture) internal pure {
        assertEq(
            capture.traceReasons.noSwaps, capture.periodClosedReasons.noSwaps, "trace/close no-swaps mismatch"
        );
        assertEq(
            capture.traceReasons.idleReset,
            capture.periodClosedReasons.idleReset,
            "trace/close idle-reset mismatch"
        );
        assertEq(
            capture.traceReasons.emaBootstrap,
            capture.periodClosedReasons.emaBootstrap,
            "trace/close bootstrap mismatch"
        );
        assertEq(
            capture.traceReasons.jumpCash,
            capture.periodClosedReasons.jumpCash,
            "trace/close jump-cash mismatch"
        );
        assertEq(
            capture.traceReasons.jumpExtreme,
            capture.periodClosedReasons.jumpExtreme,
            "trace/close jump-extreme mismatch"
        );
        assertEq(
            capture.traceReasons.downToCash,
            capture.periodClosedReasons.downToCash,
            "trace/close down-to-cash mismatch"
        );
        assertEq(
            capture.traceReasons.downToFloor,
            capture.periodClosedReasons.downToFloor,
            "trace/close down-to-floor mismatch"
        );
        assertEq(capture.traceReasons.hold, capture.periodClosedReasons.hold, "trace/close hold mismatch");
        assertEq(
            capture.traceReasons.emergencyFloor,
            capture.periodClosedReasons.emergencyFloor,
            "trace/close emergency mismatch"
        );
        assertEq(
            capture.traceReasons.noChange,
            capture.periodClosedReasons.noChange,
            "trace/close no-change mismatch"
        );
    }

    function _scenarioPeriods(Scenario scenario) internal view returns (uint64) {
        if (scenario == Scenario.CloseGap2PeriodsNoTransition) return GAP_2_PERIODS;
        if (scenario == Scenario.CloseGap8PeriodsNoTransition) return GAP_8_PERIODS;
        if (scenario == Scenario.CloseGapMaxPeriodsNoTransition) return _maxGapPeriods();
        return 0;
    }

    function _maxGapPeriods() internal view returns (uint64 periods) {
        periods = uint64((uint256(cfg.idleResetSeconds) - 1) / uint256(cfg.periodSeconds));
        require(periods > 1, "max gap periods too small");
    }

    function _oneCloseTransitionTarget(uint8 confirmPeriods) internal pure returns (uint8) {
        return confirmPeriods - 1;
    }

    function _gapDownTransitionTarget(uint8 confirmPeriods) internal pure returns (uint8) {
        return confirmPeriods > 1 ? confirmPeriods - 2 : 0;
    }

    function _gapEmergencyTransitionTarget(uint8 confirmPeriods) internal pure returns (uint8) {
        return confirmPeriods > 1 ? confirmPeriods - 2 : 0;
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
