// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {ConfigLoader} from "../../shared/lib/ConfigLoader.sol";
import {EnvLib} from "../../shared/lib/EnvLib.sol";
import {GasMeasurementLib} from "../../shared/lib/GasMeasurementLib.sol";
import {GasMeasurementLocalBase} from "../../local/foundry/GasMeasurementLocalBase.sol";
import {OpsTypes} from "../../shared/types/OpsTypes.sol";

contract MeasureGasLocalScenarioTest is Test, GasMeasurementLocalBase {
    function setUp() public {
        _setUpMeasurementEnv();
    }

    function _loadMeasurementConfig() internal view override returns (OpsTypes.CoreConfig memory cfg) {
        if (_shouldLoadEnvMeasurementConfig()) {
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

    function test_floorToCash_measurement_path_ends_in_cash() public {
        _runOperation(GasMeasurementLib.Operation.FloorToCash);
        _assertMode(hook.MODE_CASH());
    }

    function test_cashToExtreme_measurement_path_ends_in_extreme() public {
        _runOperation(GasMeasurementLib.Operation.CashToExtreme);
        _assertMode(hook.MODE_EXTREME());
    }

    function test_extremeToCash_measurement_path_ends_in_cash() public {
        _runOperation(GasMeasurementLib.Operation.ExtremeToCash);
        _assertMode(hook.MODE_CASH());
    }

    function test_cashToFloor_measurement_path_ends_in_floor() public {
        _runOperation(GasMeasurementLib.Operation.CashToFloor);
        _assertMode(hook.MODE_FLOOR());
    }
}
