// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {GasMeasurementLocalBase} from "../../local/foundry/GasMeasurementLocalBase.sol";
import {OpsTypes} from "../../shared/types/OpsTypes.sol";

contract MeasureGasLocalReportTest is Test, GasMeasurementLocalBase {
    enum Scenario {
        NormalSwapInPeriod,
        SinglePeriodClose,
        SinglePeriodCloseWithFeeChange,
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

        _assertScenario(scenario, vm.getRecordedLogs(), snapshot);
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
                || scenario == Scenario.SinglePeriodCloseWithFeeChange || scenario == Scenario.IdleReset
                || scenario == Scenario.CatchUpSmall || scenario == Scenario.CatchUpLarge
                || scenario == Scenario.CatchUpWorst || scenario == Scenario.CatchUpWithFeeChange
        ) {
            _swapStable(_minCountedStableRaw());
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

    function _accrueChunkedClaimFee() internal {
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0});
        BalanceDelta delta = toBalanceDelta(-int128(1), type(int128).max);
        manager.callAfterSwapWithParams(hook, key, params, delta);
    }

    function _assertScenario(Scenario scenario, Vm.Log[] memory logs, CounterSnapshot memory snapshot) internal view {
        LogCounts memory counts = _collectLogCounts(logs);

        if (scenario == Scenario.NormalSwapInPeriod) {
            _assertNormalSwap(counts, snapshot);
            return;
        }

        if (scenario == Scenario.SinglePeriodClose) {
            _assertSinglePeriodClose(counts, snapshot);
            return;
        }

        if (scenario == Scenario.SinglePeriodCloseWithFeeChange) {
            _assertSinglePeriodCloseWithFeeChange(counts, snapshot);
            return;
        }

        if (scenario == Scenario.IdleReset) {
            _assertIdleReset(counts, snapshot);
            return;
        }

        if (
            scenario == Scenario.CatchUpSmall || scenario == Scenario.CatchUpLarge
                || scenario == Scenario.CatchUpWorst
        ) {
            _assertCatchUp(counts, snapshot, _scenarioPeriods(scenario));
            return;
        }

        if (scenario == Scenario.CatchUpWithFeeChange) {
            _assertCatchUpWithFeeChange(counts, snapshot);
            return;
        }

        if (scenario == Scenario.ClaimHookFeesNormal) {
            _assertNormalClaim(counts, snapshot);
            return;
        }

        if (scenario == Scenario.ClaimHookFeesChunkedMulti) {
            _assertChunkedClaimMulti(counts, snapshot);
            return;
        }

        _assertChunkedClaim(counts, snapshot);
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

    function _collectLogCounts(Vm.Log[] memory logs) internal view returns (LogCounts memory counts) {
        counts.periodClosedCount = _countHookLogs(logs, PERIOD_CLOSED_SIG);
        counts.traceCount = _countHookLogs(logs, TRACE_SIG);
        counts.idleResetCount = _countHookLogs(logs, IDLE_RESET_SIG);
        counts.feeUpdatedCount = _countHookLogs(logs, FEE_UPDATED_SIG);
        counts.claimCount = _countHookLogs(logs, HOOK_FEES_CLAIMED_SIG);
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

    function _countHookLogs(Vm.Log[] memory logs, bytes32 topic0) internal view returns (uint256 count) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics.length > 0 && logs[i].topics[0] == topic0) {
                ++count;
            }
        }
    }
}
