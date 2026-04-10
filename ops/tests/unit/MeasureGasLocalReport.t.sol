// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {GasMeasurementLocalBase} from "../../local/foundry/GasMeasurementLocalBase.sol";
import {GasMeasurementLib} from "../../shared/lib/GasMeasurementLib.sol";
import {OpsTypes} from "../../shared/types/OpsTypes.sol";

contract MeasureGasLocalReportTest is Test, GasMeasurementLocalBase {
    enum Scenario {
        NormalSwapInPeriod,
        SinglePeriodClose,
        SinglePeriodCloseWithFeeChange,
        CashToFloorNormalImmediate,
        CashToFloorNormalAfterGap,
        CashToFloorEmergency,
        IdleReset,
        CatchUpSmall,
        CatchUpLarge,
        CatchUpWorst,
        CatchUpWithFeeChange,
        ClaimHookFeesNormal,
        ClaimHookFeesChunked,
        ClaimHookFeesChunkedMulti
    }

    struct LogCounts {
        uint256 periodClosedCount;
        uint256 traceCount;
        uint256 idleResetCount;
        uint256 feeUpdatedCount;
        uint256 claimCount;
    }

    struct CounterSnapshot {
        uint256 updateBefore;
        uint256 unlockBefore;
        uint256 burnBefore;
        uint256 takeBefore;
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

    uint64 internal constant CASH_TO_FLOOR_AFTER_GAP_PERIODS = 2;
    uint64 internal constant CATCH_UP_SMALL_PERIODS = 2;
    uint64 internal constant CATCH_UP_LARGE_PERIODS = 8;
    uint64 internal constant CATCH_UP_WORST_PERIODS = 23;
    uint64 internal constant CATCH_UP_WITH_FEE_CHANGE_PERIODS = 2;
    uint256 internal constant LARGE_CLAIM_SWAP_COUNT = 11;
    uint256 internal constant LARGE_CLAIM_MULTI_SWAP_COUNT = 21;
    uint24 internal constant LARGE_CLAIM_FLOOR_FEE = 999_998;
    uint24 internal constant LARGE_CLAIM_CASH_FEE = 999_999;
    uint24 internal constant LARGE_CLAIM_EXTREME_FEE = 1_000_000;
    uint256 internal constant POOL_MANAGER_SETTLEMENT_LIMIT = uint256(uint128(type(int128).max));
    uint16 internal constant TRACE_FLAG_EMERGENCY_TRIGGERED = 0x0008;

    bool internal _useLargeClaimConfig;

    bytes32 internal constant PERIOD_CLOSED_SIG =
        keccak256("PeriodClosed(uint24,uint8,uint24,uint8,uint64,uint96,uint64,uint8)");
    bytes32 internal constant TRACE_SIG =
        keccak256(
            "ControllerTransitionTrace(uint64,uint24,uint8,uint24,uint8,uint64,uint96,uint96,uint64,uint16,uint16,uint16,uint8)"
        );
    bytes32 internal constant IDLE_RESET_SIG = keccak256("IdleReset(uint24,uint8)");
    bytes32 internal constant FEE_UPDATED_SIG = keccak256("FeeUpdated(uint24,uint8,uint64,uint96)");
    bytes32 internal constant HOOK_FEES_CLAIMED_SIG = keccak256("HookFeesClaimed(address,uint256,uint256)");

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

        if (_useLargeClaimConfig) {
            cfg.floorFeePips = LARGE_CLAIM_FLOOR_FEE;
            cfg.cashFeePips = LARGE_CLAIM_CASH_FEE;
            cfg.extremeFeePips = LARGE_CLAIM_EXTREME_FEE;
        }
    }

    function testGas_normal_swap_in_period() public {
        _runMeasuredScenario(Scenario.NormalSwapInPeriod);
    }

    function testGas_single_period_close() public {
        _runMeasuredScenario(Scenario.SinglePeriodClose);
    }

    function testGas_single_period_close_with_fee_change() public {
        _runMeasuredScenario(Scenario.SinglePeriodCloseWithFeeChange);
    }

    function testGas_cash_to_floor_normal_immediate() public {
        _runMeasuredScenario(Scenario.CashToFloorNormalImmediate);
    }

    function testGas_cash_to_floor_normal_after_gap() public {
        _runMeasuredScenario(Scenario.CashToFloorNormalAfterGap);
    }

    function testGas_cash_to_floor_emergency() public {
        _runMeasuredScenario(Scenario.CashToFloorEmergency);
    }

    function testGas_idle_reset() public {
        _runMeasuredScenario(Scenario.IdleReset);
    }

    function testGas_catch_up_small() public {
        _runMeasuredScenario(Scenario.CatchUpSmall);
    }

    function testGas_catch_up_large() public {
        _runMeasuredScenario(Scenario.CatchUpLarge);
    }

    function testGas_catch_up_worst() public {
        _runMeasuredScenario(Scenario.CatchUpWorst);
    }

    function testGas_catch_up_with_fee_change() public {
        _runMeasuredScenario(Scenario.CatchUpWithFeeChange);
    }

    function testGas_claim_hook_fees_normal() public {
        _runMeasuredScenario(Scenario.ClaimHookFeesNormal);
    }

    function testGas_claim_hook_fees_chunked() public {
        _runMeasuredScenario(Scenario.ClaimHookFeesChunked);
    }

    function testGas_claim_hook_fees_chunked_multi() public {
        _runMeasuredScenario(Scenario.ClaimHookFeesChunkedMulti);
    }

    function _runMeasuredScenario(Scenario scenario) internal {
        vm.pauseGasMetering();
        _setUpScenario(scenario);
        StateSnapshot memory beforeState = _captureState();

        bool ownerOp = _requiresOwnerPrank(scenario);
        address ownerAddr = vm.addr(cfg.privateKey);
        CounterSnapshot memory snapshot = CounterSnapshot({
            updateBefore: manager.updateCount(),
            unlockBefore: manager.unlockCount(),
            burnBefore: manager.burnCount(),
            takeBefore: manager.takeCount()
        });

        vm.recordLogs();
        if (ownerOp) {
            vm.startPrank(ownerAddr);
        }

        vm.resumeGasMetering();
        _executeScenario(scenario);
        vm.pauseGasMetering();

        if (ownerOp) {
            vm.stopPrank();
        }

        StateSnapshot memory afterState = _captureState();
        _assertScenario(scenario, beforeState, afterState, vm.getRecordedLogs(), snapshot);
    }

    function _setUpScenario(Scenario scenario) internal {
        if (scenario == Scenario.ClaimHookFeesChunked) {
            _setUpLargeClaimMeasurementEnv(LARGE_CLAIM_SWAP_COUNT, 2);
            return;
        }

        if (scenario == Scenario.ClaimHookFeesChunkedMulti) {
            _setUpLargeClaimMeasurementEnv(LARGE_CLAIM_MULTI_SWAP_COUNT, 3);
            return;
        }

        _setUpMeasurementEnv();

        if (scenario == Scenario.NormalSwapInPeriod) {
            _swapStable(_minCountedStableRaw());
            return;
        }

        if (scenario == Scenario.SinglePeriodClose) {
            _swapStable(_seedStableRaw());
            _warpPeriods(1);
            return;
        }

        if (scenario == Scenario.SinglePeriodCloseWithFeeChange) {
            // Measured call closes one qualifying period and transitions FLOOR -> CASH.
            _primeFloorToCash();
            _warpPeriods(1);
            return;
        }

        if (scenario == Scenario.CashToFloorNormalImmediate) {
            _setUpCashToFloorNormalImmediate();
            return;
        }

        if (scenario == Scenario.CashToFloorNormalAfterGap) {
            _setUpCashToFloorNormalAfterGap();
            return;
        }

        if (scenario == Scenario.CashToFloorEmergency) {
            _setUpCashToFloorEmergency();
            return;
        }

        if (scenario == Scenario.IdleReset) {
            _moveToCash();
            vm.warp(block.timestamp + uint256(cfg.idleResetSeconds) + 1);
            return;
        }

        if (scenario == Scenario.CatchUpSmall) {
            _prepareCatchUp(CATCH_UP_SMALL_PERIODS);
            return;
        }

        if (scenario == Scenario.CatchUpLarge) {
            _prepareCatchUp(CATCH_UP_LARGE_PERIODS);
            return;
        }

        if (scenario == Scenario.CatchUpWorst) {
            _prepareCatchUp(CATCH_UP_WORST_PERIODS);
            return;
        }

        if (scenario == Scenario.CatchUpWithFeeChange) {
            // Measured call catches up two overdue periods; the first overdue close transitions FLOOR -> CASH.
            _primeFloorToCash();
            _warpPeriods(CATCH_UP_WITH_FEE_CHANGE_PERIODS);
            return;
        }

        if (scenario == Scenario.ClaimHookFeesNormal) {
            _swapStable(_minCountedStableRaw());
        }
    }

    function _executeScenario(Scenario scenario) internal {
        if (
            scenario == Scenario.NormalSwapInPeriod || scenario == Scenario.SinglePeriodClose
                || scenario == Scenario.SinglePeriodCloseWithFeeChange
                || scenario == Scenario.CashToFloorNormalImmediate
                || scenario == Scenario.CashToFloorNormalAfterGap || scenario == Scenario.CashToFloorEmergency
                || scenario == Scenario.IdleReset || scenario == Scenario.CatchUpSmall
                || scenario == Scenario.CatchUpLarge || scenario == Scenario.CatchUpWorst
                || scenario == Scenario.CatchUpWithFeeChange
        ) {
            _swapStable(_measuredSwapAmountStableRaw(scenario));
            return;
        }

        hook.claimHookFees();
    }

    function _prepareCatchUp(uint64 periods) internal {
        require(periods > 1, "catch-up periods too small");
        require(periods * uint64(cfg.periodSeconds) < uint64(cfg.idleResetSeconds), "catch-up crosses idle reset");

        _swapStable(_seedStableRaw());
        _warpPeriods(periods);
    }

    function _setUpCashToFloorNormalImmediate() internal {
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

    function _setUpCashToFloorNormalAfterGap() internal {
        require(cfg.exitCashConfirmPeriods >= 3, "gap down needs >=3 confirms");
        require(
            CASH_TO_FLOOR_AFTER_GAP_PERIODS * uint64(cfg.periodSeconds) < uint64(cfg.idleResetSeconds),
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
        assertEq(preGapState.holdRemaining, 0, "gap-down setup must finish hold before the overdue gap");
        assertEq(
            preGapState.downStreak,
            cfg.exitCashConfirmPeriods - 2,
            "gap-down setup must leave two overdue closes for the ordinary descent"
        );
        assertEq(preGapState.emergencyStreak, 0, "gap-down setup must avoid emergency reset before the gap");

        _warpPeriods(CASH_TO_FLOOR_AFTER_GAP_PERIODS);
    }

    function _setUpCashToFloorEmergency() internal {
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
        if (scenario == Scenario.CashToFloorNormalImmediate || scenario == Scenario.CashToFloorNormalAfterGap) {
            return _ordinaryCashWeakStableRaw();
        }

        return _minCountedStableRaw();
    }

    function _accrueChunkedClaimFee() internal {
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0});
        BalanceDelta delta = toBalanceDelta(-int128(1), type(int128).max);
        manager.callAfterSwapWithParams(hook, key, params, delta);
    }

    function _assertScenario(
        Scenario scenario,
        StateSnapshot memory beforeState,
        StateSnapshot memory afterState,
        Vm.Log[] memory logs,
        CounterSnapshot memory snapshot
    ) internal view {
        ScenarioLogCapture memory capture = _collectLogCapture(logs);

        if (scenario == Scenario.NormalSwapInPeriod) {
            _assertNormalSwap(capture.counts, snapshot);
            return;
        }

        if (scenario == Scenario.SinglePeriodClose) {
            _assertSinglePeriodClose(capture.counts, snapshot);
            return;
        }

        if (scenario == Scenario.SinglePeriodCloseWithFeeChange) {
            _assertSinglePeriodCloseWithFeeChange(capture.counts, snapshot);
            return;
        }

        if (scenario == Scenario.CashToFloorNormalImmediate) {
            _assertCashToFloorNormalImmediate(beforeState, afterState, capture, snapshot);
            return;
        }

        if (scenario == Scenario.CashToFloorNormalAfterGap) {
            _assertCashToFloorNormalAfterGap(beforeState, afterState, capture, snapshot);
            return;
        }

        if (scenario == Scenario.CashToFloorEmergency) {
            _assertCashToFloorEmergency(beforeState, afterState, capture, snapshot);
            return;
        }

        if (scenario == Scenario.IdleReset) {
            _assertIdleReset(capture.counts, snapshot);
            return;
        }

        if (
            scenario == Scenario.CatchUpSmall || scenario == Scenario.CatchUpLarge
                || scenario == Scenario.CatchUpWorst
        ) {
            _assertCatchUp(capture.counts, snapshot, _scenarioPeriods(scenario));
            return;
        }

        if (scenario == Scenario.CatchUpWithFeeChange) {
            _assertCatchUpWithFeeChange(capture.counts, snapshot);
            return;
        }

        if (scenario == Scenario.ClaimHookFeesNormal) {
            _assertNormalClaim(capture.counts, snapshot);
            return;
        }

        if (scenario == Scenario.ClaimHookFeesChunkedMulti) {
            _assertChunkedClaimMulti(capture.counts, snapshot);
            return;
        }

        _assertChunkedClaim(capture.counts, snapshot);
    }

    function _setUpLargeClaimMeasurementEnv(uint256 swapCount, uint256 expectedChunks) internal {
        _useLargeClaimConfig = true;
        _setUpMeasurementEnv();
        _useLargeClaimConfig = false;

        for (uint256 i = 0; i < swapCount; ++i) {
            _accrueChunkedClaimFee();
        }

        (uint256 fees0, uint256 fees1) = hook.hookFeesAccrued();
        uint256 lowerBound = POOL_MANAGER_SETTLEMENT_LIMIT * (expectedChunks - 1);
        uint256 upperBound = POOL_MANAGER_SETTLEMENT_LIMIT * expectedChunks;

        assertEq(fees0, 0, "large-claim setup must accrue only token1");
        assertGt(fees1, lowerBound, "large-claim setup must exceed the previous chunk bound");
        assertLe(fees1, upperBound, "large-claim setup must stay within the exact chunk count");
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

    function _assertSinglePeriodClose(LogCounts memory counts, CounterSnapshot memory snapshot) internal view {
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

    function _assertSinglePeriodCloseWithFeeChange(LogCounts memory counts, CounterSnapshot memory snapshot)
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

    function _assertCashToFloorNormalImmediate(
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

    function _assertCashToFloorNormalAfterGap(
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
            "ordinary gap path must start two overdue closes short of cash->floor"
        );
        assertEq(beforeState.emergencyStreak, 0, "ordinary gap path must not preload emergency reset");

        assertEq(
            capture.counts.periodClosedCount,
            CASH_TO_FLOOR_AFTER_GAP_PERIODS,
            "ordinary gap path must close the expected overdue periods"
        );
        assertEq(
            capture.counts.traceCount,
            CASH_TO_FLOOR_AFTER_GAP_PERIODS,
            "ordinary gap path must emit one trace per overdue close"
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

    function _assertCashToFloorEmergency(
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

    function _assertCatchUp(LogCounts memory counts, CounterSnapshot memory snapshot, uint64 expectedPeriods)
        internal
        view
    {
        (uint64 periodVolume,, uint64 periodStart, uint8 feeIdx) = hook.unpackedState();
        assertEq(counts.periodClosedCount, expectedPeriods, "catch-up must close the expected number of periods");
        assertEq(counts.traceCount, expectedPeriods, "catch-up must emit one trace per closed period");
        assertEq(counts.idleResetCount, 0, "catch-up must stay below idle reset");
        assertEq(counts.feeUpdatedCount, 0, "floor-mode catch-up baseline must avoid fee updates");
        assertEq(periodVolume, _minCountedUsd6(), "catch-up must count the current swap into the fresh period");
        assertEq(feeIdx, hook.MODE_FLOOR(), "floor-mode catch-up baseline stays in floor mode");
        assertGt(periodStart, 0, "catch-up must preserve initialized period start");
        assertEq(manager.updateCount(), snapshot.updateBefore, "catch-up baseline must not update LP fee");
    }

    function _assertCatchUpWithFeeChange(LogCounts memory counts, CounterSnapshot memory snapshot) internal view {
        (uint64 periodVolume,, uint64 periodStart, uint8 feeIdx) = hook.unpackedState();
        assertEq(
            counts.periodClosedCount,
            CATCH_UP_WITH_FEE_CHANGE_PERIODS,
            "transition catch-up must close the expected number of periods"
        );
        assertEq(
            counts.traceCount,
            CATCH_UP_WITH_FEE_CHANGE_PERIODS,
            "transition catch-up must emit one trace per closed period"
        );
        assertEq(counts.idleResetCount, 0, "transition catch-up must stay below idle reset");
        assertEq(counts.feeUpdatedCount, 1, "transition catch-up must emit one fee sync");
        assertEq(periodVolume, _minCountedUsd6(), "transition catch-up must count the current swap into the fresh period");
        assertEq(feeIdx, hook.MODE_CASH(), "scenario must include a FLOOR -> CASH transition");
        assertGt(periodStart, 0, "transition catch-up must preserve initialized period start");
        assertEq(manager.updateCount(), snapshot.updateBefore + 1, "transition catch-up must perform one LP fee update");
    }

    function _assertNormalClaim(LogCounts memory counts, CounterSnapshot memory snapshot) internal view {
        (uint256 fees0, uint256 fees1) = hook.hookFeesAccrued();
        assertEq(counts.claimCount, 1, "normal claim must emit one claim event");
        assertEq(counts.periodClosedCount, 0, "claim must not emit period-close telemetry");
        assertEq(counts.traceCount, 0, "claim must not emit controller trace");
        assertEq(counts.idleResetCount, 0, "claim must not idle reset");
        assertEq(counts.feeUpdatedCount, 0, "claim must not touch LP fee");
        assertEq(fees0, 0, "normal claim setup accrues only token1");
        assertEq(fees1, 0, "normal claim must clear token1 accrual");
        assertEq(manager.updateCount(), snapshot.updateBefore, "claim must not update LP fee");
        assertEq(manager.unlockCount(), snapshot.unlockBefore + 1, "normal claim must use one unlock");
        assertEq(manager.burnCount(), snapshot.burnBefore + 1, "normal claim must use one burn chunk");
        assertEq(manager.takeCount(), snapshot.takeBefore + 1, "normal claim must use one take chunk");
    }

    function _assertChunkedClaim(LogCounts memory counts, CounterSnapshot memory snapshot) internal view {
        (uint256 fees0, uint256 fees1) = hook.hookFeesAccrued();
        assertEq(counts.claimCount, 1, "chunked claim must emit one claim event");
        assertEq(counts.periodClosedCount, 0, "chunked claim must not emit period-close telemetry");
        assertEq(counts.traceCount, 0, "chunked claim must not emit controller trace");
        assertEq(counts.idleResetCount, 0, "chunked claim must not idle reset");
        assertEq(counts.feeUpdatedCount, 0, "chunked claim must not touch LP fee");
        assertEq(fees0, 0, "chunked claim setup accrues only token1");
        assertEq(fees1, 0, "chunked claim must clear token1 accrual");
        assertEq(manager.updateCount(), snapshot.updateBefore, "claim must not update LP fee");
        assertEq(manager.unlockCount(), snapshot.unlockBefore + 1, "chunked claim must still use one unlock");
        assertEq(manager.burnCount(), snapshot.burnBefore + 2, "chunked claim must burn in two chunks");
        assertEq(manager.takeCount(), snapshot.takeBefore + 2, "chunked claim must take in two chunks");
    }

    function _assertChunkedClaimMulti(LogCounts memory counts, CounterSnapshot memory snapshot) internal view {
        (uint256 fees0, uint256 fees1) = hook.hookFeesAccrued();
        assertEq(counts.claimCount, 1, "multi-chunk claim must emit one claim event");
        assertEq(counts.periodClosedCount, 0, "multi-chunk claim must not emit period-close telemetry");
        assertEq(counts.traceCount, 0, "multi-chunk claim must not emit controller trace");
        assertEq(counts.idleResetCount, 0, "multi-chunk claim must not idle reset");
        assertEq(counts.feeUpdatedCount, 0, "multi-chunk claim must not touch LP fee");
        assertEq(fees0, 0, "multi-chunk claim setup accrues only token1");
        assertEq(fees1, 0, "multi-chunk claim must clear token1 accrual");
        assertEq(manager.updateCount(), snapshot.updateBefore, "claim must not update LP fee");
        assertEq(manager.unlockCount(), snapshot.unlockBefore + 1, "multi-chunk claim must still use one unlock");
        assertEq(manager.burnCount(), snapshot.burnBefore + 3, "multi-chunk claim must burn in three chunks");
        assertEq(manager.takeCount(), snapshot.takeBefore + 3, "multi-chunk claim must take in three chunks");
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

            if (topic0 == HOOK_FEES_CLAIMED_SIG) {
                capture.counts.claimCount += 1;
            }
        }
    }

    function _requiresOwnerPrank(Scenario scenario) internal pure returns (bool) {
        return scenario == Scenario.ClaimHookFeesNormal || scenario == Scenario.ClaimHookFeesChunked
            || scenario == Scenario.ClaimHookFeesChunkedMulti;
    }

    function _scenarioPeriods(Scenario scenario) internal pure returns (uint64) {
        if (scenario == Scenario.CatchUpSmall) return CATCH_UP_SMALL_PERIODS;
        if (scenario == Scenario.CatchUpLarge) return CATCH_UP_LARGE_PERIODS;
        if (scenario == Scenario.CatchUpWorst) return CATCH_UP_WORST_PERIODS;
        if (scenario == Scenario.CatchUpWithFeeChange) return CATCH_UP_WITH_FEE_CHANGE_PERIODS;
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
