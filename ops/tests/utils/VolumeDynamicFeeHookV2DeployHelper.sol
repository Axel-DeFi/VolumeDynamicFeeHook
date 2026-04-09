// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {VolumeDynamicFeeHook} from "src/VolumeDynamicFeeHook.sol";

abstract contract VolumeDynamicFeeHookV2DeployHelper {
    uint64 internal constant V2_ENTER_CASH_MIN_VOLUME = 400 * 1e6;
    uint16 internal constant V2_ENTER_CASH_EMA_RATIO_PCT = 135;
    uint8 internal constant V2_HOLD_CASH_PERIODS = 2;

    uint64 internal constant V2_ENTER_EXTREME_MIN_VOLUME = 2_500 * 1e6;
    uint16 internal constant V2_ENTER_EXTREME_EMA_RATIO_PCT = 410;
    uint8 internal constant V2_ENTER_EXTREME_CONFIRM_PERIODS = 2;
    uint8 internal constant V2_HOLD_EXTREME_PERIODS = 2;

    uint16 internal constant V2_EXIT_EXTREME_EMA_RATIO_PCT = 120;
    uint8 internal constant V2_EXIT_EXTREME_CONFIRM_PERIODS = 2;
    uint16 internal constant V2_EXIT_CASH_EMA_RATIO_PCT = 120;
    uint8 internal constant V2_EXIT_CASH_CONFIRM_PERIODS = 3;

    uint64 internal constant V2_LOW_VOLUME_RESET = 100 * 1e6;
    uint8 internal constant V2_LOW_VOLUME_RESET_PERIODS = 6;

    uint16 internal constant V2_INITIAL_HOOK_FEE_PERCENT = 3;

    uint24 internal constant V2_DEFAULT_FLOOR_FEE = 400;
    uint24 internal constant V2_DEFAULT_CASH_FEE = 2_500;
    uint24 internal constant V2_DEFAULT_EXTREME_FEE = 9_000;

    function _constructorArgsV2(
        IPoolManager poolManager,
        Currency currency0,
        Currency currency1,
        int24 tickSpacing,
        Currency stableCurrency,
        uint8 stableDecimals,
        uint24 floorFee,
        uint24 cashFee,
        uint24 extremeFee,
        uint32 periodSeconds,
        uint8 emaPeriods,
        uint32 idleResetSeconds,
        address owner,
        uint16 hookFeePercent
    ) internal pure returns (bytes memory) {
        return abi.encode(
            poolManager,
            currency0,
            currency1,
            tickSpacing,
            stableCurrency,
            stableDecimals,
            floorFee,
            cashFee,
            extremeFee,
            periodSeconds,
            emaPeriods,
            idleResetSeconds,
            owner,
            hookFeePercent,
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
    }

    function _deployHookV2(
        IPoolManager poolManager,
        Currency currency0,
        Currency currency1,
        int24 tickSpacing,
        Currency stableCurrency,
        uint8 stableDecimals,
        uint24 floorFee,
        uint24 cashFee,
        uint24 extremeFee,
        uint32 periodSeconds,
        uint8 emaPeriods,
        uint32 idleResetSeconds,
        address owner,
        uint16 hookFeePercent
    ) internal returns (VolumeDynamicFeeHook hook) {
        hook = new VolumeDynamicFeeHook(
            poolManager,
            currency0,
            currency1,
            tickSpacing,
            stableCurrency,
            stableDecimals,
            floorFee,
            cashFee,
            extremeFee,
            periodSeconds,
            emaPeriods,
            idleResetSeconds,
            owner,
            hookFeePercent,
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
    }

    function _deployHookV2(
        bytes32 salt,
        IPoolManager poolManager,
        Currency currency0,
        Currency currency1,
        int24 tickSpacing,
        Currency stableCurrency,
        uint8 stableDecimals,
        uint24 floorFee,
        uint24 cashFee,
        uint24 extremeFee,
        uint32 periodSeconds,
        uint8 emaPeriods,
        uint32 idleResetSeconds,
        address owner,
        uint16 hookFeePercent
    ) internal returns (VolumeDynamicFeeHook hook) {
        hook = new VolumeDynamicFeeHook{salt: salt}(
            poolManager,
            currency0,
            currency1,
            tickSpacing,
            stableCurrency,
            stableDecimals,
            floorFee,
            cashFee,
            extremeFee,
            periodSeconds,
            emaPeriods,
            idleResetSeconds,
            owner,
            hookFeePercent,
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
    }
}
