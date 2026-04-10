// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {BaseHook} from "@uniswap/v4-hooks-public/src/base/BaseHook.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {VolumeDynamicFeeHook} from "src/VolumeDynamicFeeHook.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {VolumeDynamicFeeHookV2DeployHelper} from "../utils/VolumeDynamicFeeHookV2DeployHelper.sol";

contract VolumeDynamicFeeHookEchidnaDeployHarness is VolumeDynamicFeeHook {
    constructor(
        IPoolManager _poolManager,
        Currency _poolCurrency0,
        Currency _poolCurrency1,
        int24 _poolTickSpacing,
        Currency _stableCurrency,
        uint8 stableDecimals,
        uint24 _floorFee,
        uint24 _cashFee,
        uint24 _extremeFee,
        uint32 _periodSeconds,
        uint8 _emaPeriods,
        uint32 _idleResetSeconds,
        address ownerAddr,
        uint16 hookFeePercent,
        uint64 _enterCashMinVolume,
        uint16 _enterCashEmaRatioPct,
        uint8 _holdCashPeriods,
        uint64 _enterExtremeMinVolume,
        uint16 _enterExtremeEmaRatioPct,
        uint8 _enterExtremeConfirmPeriods,
        uint8 _holdExtremePeriods,
        uint16 _exitExtremeEmaRatioPct,
        uint8 _exitExtremeConfirmPeriods,
        uint16 _exitCashEmaRatioPct,
        uint8 _exitCashConfirmPeriods,
        uint64 _lowVolumeReset,
        uint8 _lowVolumeResetPeriods
    )
        VolumeDynamicFeeHook(
            _poolManager,
            _poolCurrency0,
            _poolCurrency1,
            _poolTickSpacing,
            _stableCurrency,
            stableDecimals,
            _floorFee,
            _cashFee,
            _extremeFee,
            _periodSeconds,
            _emaPeriods,
            _idleResetSeconds,
            ownerAddr,
            hookFeePercent,
            _enterCashMinVolume,
            _enterCashEmaRatioPct,
            _holdCashPeriods,
            _enterExtremeMinVolume,
            _enterExtremeEmaRatioPct,
            _enterExtremeConfirmPeriods,
            _holdExtremePeriods,
            _exitExtremeEmaRatioPct,
            _exitExtremeConfirmPeriods,
            _exitCashEmaRatioPct,
            _exitCashConfirmPeriods,
            _lowVolumeReset,
            _lowVolumeResetPeriods
        )
    {}

    function validateHookAddress(BaseHook) internal pure override {}
}

contract VolumeDynamicFeeHookEchidnaHarness is VolumeDynamicFeeHookV2DeployHelper {
    MockPoolManager internal manager;
    VolumeDynamicFeeHookEchidnaDeployHarness internal hook;
    PoolKey internal key;

    uint64 internal lastObservedPeriodStart;
    bool internal periodStartMonotonic = true;

    constructor() {
        manager = new MockPoolManager();

        Currency c0 = Currency.wrap(address(0x0000000000000000000000000000000000001111));
        Currency c1 = Currency.wrap(address(0x0000000000000000000000000000000000002222));

        hook = new VolumeDynamicFeeHookEchidnaDeployHarness(
            IPoolManager(address(manager)),
            c0,
            c1,
            10,
            c1,
            6,
            V2_DEFAULT_FLOOR_FEE,
            V2_DEFAULT_CASH_FEE,
            V2_DEFAULT_EXTREME_FEE,
            300,
            8,
            3600,
            address(this),
            V2_INITIAL_HOOK_FEE_PERCENT,
            V2_ENTER_CASH_MIN_VOLUME,
            V2_ENTER_CASH_EMA_RATIO_PCT,
            V2_HOLD_CASH_PERIODS,
            V2_ENTER_EXTREME_MIN_VOLUME,
            V2_ENTER_EXTREME_EMA_RATIO_PCT,
            V2_ENTER_EXTREME_CONFIRM_PERIODS,
            V2_HOLD_EXTREME_PERIODS,
            V2_EXIT_EXTREME_EMA_RATIO_PCT,
            V2_EXIT_EXTREME_CONFIRM_PERIODS,
            V2_EXIT_CASH_EMA_RATIO_PCT,
            V2_EXIT_CASH_CONFIRM_PERIODS,
            V2_LOW_VOLUME_RESET,
            V2_LOW_VOLUME_RESET_PERIODS
        );

        key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });

        manager.callAfterInitialize(hook, key);
        (,, lastObservedPeriodStart,) = hook.unpackedState();
        _recordPostState();
    }

    function swapCounted(uint128 amountStable6) public {
        uint128 amt = amountStable6;
        if (amt > uint128(type(int128).max)) amt = uint128(type(int128).max);

        uint128 otherSide = uint128((uint256(amt) * 95) / 100);
        manager.callAfterSwap(hook, key, toBalanceDelta(int128(otherSide), -int128(amt)));
        _recordPostState();
    }

    function closeZero() public {
        manager.callAfterSwap(hook, key, toBalanceDelta(0, 0));
        _recordPostState();
    }

    function pauseController() public {
        hook.pause();
        _recordPostState();
    }

    function unpauseController() public {
        hook.unpause();
        _recordPostState();
    }

    function emergencyFloor() public {
        if (hook.isPaused()) {
            hook.emergencyReset(hook.MODE_FLOOR());
        }
        _recordPostState();
    }

    function emergencyCash() public {
        if (hook.isPaused()) {
            hook.emergencyReset(hook.MODE_CASH());
        }
        _recordPostState();
    }

    function setControllerHolds(uint8 nextCashHold, uint8 nextExtremeHold) public {
        VolumeDynamicFeeHook.ControllerSettings memory p = hook.getControllerSettings();
        p.holdCashPeriods = uint8(1 + (uint256(nextCashHold) % 15));
        p.holdExtremePeriods = uint8(1 + (uint256(nextExtremeHold) % 15));
        hook.setControllerSettings(p);
        _recordPostState();
    }

    function scheduleHookFee(uint16 nextPercent) public {
        (bool exists,,) = hook.pendingHookFeeChange();
        if (!exists) {
            hook.scheduleHookFeeChange(nextPercent % 11);
        }
        _recordPostState();
    }

    function cancelHookFee() public {
        (bool exists,,) = hook.pendingHookFeeChange();
        if (exists) {
            hook.cancelHookFeeChange();
        }
        _recordPostState();
    }

    function executeHookFee() public {
        (bool exists,, uint64 executeAfter) = hook.pendingHookFeeChange();
        if (exists && block.timestamp >= executeAfter) {
            hook.executeHookFeeChange();
        }
        _recordPostState();
    }

    function echidna_current_lp_fee_matches_mode() public view returns (bool) {
        uint8 feeIdx = hook.currentMode();
        uint24 expectedFee =
            feeIdx == hook.MODE_FLOOR() ? hook.floorFee() : feeIdx == hook.MODE_CASH() ? hook.cashFee() : hook.extremeFee();
        return manager.lastFee() == expectedFee;
    }

    function echidna_hold_respects_current_mode_config() public view returns (bool) {
        (uint8 feeIdx, uint8 holdRemaining,,,,,,,) = hook.getStateDebug();

        if (feeIdx == hook.MODE_FLOOR()) {
            return holdRemaining == 0;
        }
        if (feeIdx == hook.MODE_CASH()) {
            return holdRemaining <= hook.holdCashPeriods();
        }
        return holdRemaining <= hook.holdExtremePeriods();
    }

    function echidna_counters_stay_within_bounds() public view returns (bool) {
        (uint8 feeIdx, uint8 holdRemaining, uint8 upExtremeStreak, uint8 downStreak, uint8 emergencyStreak,,,,) =
            hook.getStateDebug();

        return feeIdx <= hook.MODE_EXTREME() && holdRemaining <= 15 && upExtremeStreak <= 7 && downStreak <= 15
            && emergencyStreak <= 15;
    }

    function echidna_pending_timelock_state_consistent() public view returns (bool) {
        (bool exists, uint16 nextValue, uint64 executeAfter) = hook.pendingHookFeeChange();
        if (!exists) {
            return nextValue == 0 && executeAfter == 0;
        }
        return nextValue <= 10 && executeAfter > 0;
    }

    function echidna_period_start_is_monotonic() public view returns (bool) {
        return periodStartMonotonic;
    }

    function _recordPostState() internal {
        (,,,,, uint64 periodStart,,,) = hook.getStateDebug();
        if (periodStart < lastObservedPeriodStart) {
            periodStartMonotonic = false;
        }
        lastObservedPeriodStart = periodStart;
    }
}
