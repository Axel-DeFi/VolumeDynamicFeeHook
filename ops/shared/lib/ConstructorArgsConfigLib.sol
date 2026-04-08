// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {OpsTypes} from "../types/OpsTypes.sol";

library ConstructorArgsConfigLib {
    function toDeploymentConfig(bytes memory constructorArgs)
        internal
        pure
        returns (OpsTypes.DeploymentConfig memory cfg)
    {
        (
            address poolManager,
            address poolCurrency0,
            address poolCurrency1,
            int24 poolTickSpacing,
            address stableCurrency,
            uint8 stableDecimals,
            uint24 floorFeePips,
            uint24 cashFeePips,
            uint24 extremeFeePips,
            uint32 periodSeconds,
            uint8 emaPeriods,
            uint32 idleResetSeconds,
            address owner,
            uint16 hookFeePercent,
            uint64 enterCashMinVolume,
            uint16 enterCashEmaRatioPct,
            uint8 holdCashPeriods,
            uint64 enterExtremeMinVolume,
            uint16 enterExtremeEmaRatioPct,
            uint8 enterExtremeConfirmPeriods,
            uint8 holdExtremePeriods,
            uint16 exitExtremeEmaRatioPct,
            uint8 exitExtremeConfirmPeriods,
            uint16 exitCashEmaRatioPct,
            uint8 exitCashConfirmPeriods,
            uint64 lowVolumeReset,
            uint8 lowVolumeResetPeriods
        ) = abi.decode(
            constructorArgs,
            (
                address,
                address,
                address,
                int24,
                address,
                uint8,
                uint24,
                uint24,
                uint24,
                uint32,
                uint8,
                uint32,
                address,
                uint16,
                uint64,
                uint16,
                uint8,
                uint64,
                uint16,
                uint8,
                uint8,
                uint16,
                uint8,
                uint16,
                uint8,
                uint64,
                uint8
            )
        );

        cfg.poolManager = poolManager;
        cfg.owner = owner;
        cfg.stableToken = stableCurrency;
        cfg.token0 = poolCurrency0;
        cfg.token1 = poolCurrency1;
        cfg.stableDecimals = stableDecimals;
        cfg.tickSpacing = poolTickSpacing;
        cfg.floorFeePips = floorFeePips;
        cfg.cashFeePips = cashFeePips;
        cfg.extremeFeePips = extremeFeePips;
        cfg.periodSeconds = periodSeconds;
        cfg.emaPeriods = emaPeriods;
        cfg.idleResetSeconds = idleResetSeconds;
        cfg.hookFeePercent = hookFeePercent;
        cfg.enterCashMinVolume = enterCashMinVolume;
        cfg.enterCashEmaRatioPct = enterCashEmaRatioPct;
        cfg.holdCashPeriods = holdCashPeriods;
        cfg.enterExtremeMinVolume = enterExtremeMinVolume;
        cfg.enterExtremeEmaRatioPct = enterExtremeEmaRatioPct;
        cfg.enterExtremeConfirmPeriods = enterExtremeConfirmPeriods;
        cfg.holdExtremePeriods = holdExtremePeriods;
        cfg.exitExtremeEmaRatioPct = exitExtremeEmaRatioPct;
        cfg.exitExtremeConfirmPeriods = exitExtremeConfirmPeriods;
        cfg.exitCashEmaRatioPct = exitCashEmaRatioPct;
        cfg.exitCashConfirmPeriods = exitCashConfirmPeriods;
        cfg.lowVolumeReset = lowVolumeReset;
        cfg.lowVolumeResetPeriods = lowVolumeResetPeriods;
    }
}
