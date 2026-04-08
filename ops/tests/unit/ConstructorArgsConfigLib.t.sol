// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ConstructorArgsConfigLib} from "../../shared/lib/ConstructorArgsConfigLib.sol";
import {HookIdentityLib} from "../../shared/lib/HookIdentityLib.sol";
import {OpsTypes} from "../../shared/types/OpsTypes.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {VolumeDynamicFeeHookV2DeployHelper} from "../utils/VolumeDynamicFeeHookV2DeployHelper.sol";

contract ConstructorArgsConfigLibTest is Test, VolumeDynamicFeeHookV2DeployHelper {
    address internal constant TOKEN0 = address(0x0000000000000000000000000000000000001111);
    address internal constant TOKEN1 = address(0x0000000000000000000000000000000000002222);
    int24 internal constant TICK_SPACING = 10;
    uint32 internal constant PERIOD_SECONDS = 300;
    uint32 internal constant LULL_RESET_SECONDS = 3600;
    uint8 internal constant EMA_PERIODS = 8;

    MockPoolManager internal manager;

    function setUp() public {
        manager = new MockPoolManager();
    }

    function test_toDeploymentConfig_roundTrips_constructor_identity() public view {
        OpsTypes.DeploymentConfig memory original = _cfg(address(this), 18, V2_INITIAL_HOOK_FEE_PERCENT);
        bytes memory args = HookIdentityLib.constructorArgs(original);

        OpsTypes.DeploymentConfig memory decoded = ConstructorArgsConfigLib.toDeploymentConfig(args);

        assertEq(decoded.poolManager, original.poolManager);
        assertEq(decoded.owner, original.owner);
        assertEq(decoded.stableToken, original.stableToken);
        assertEq(decoded.token0, original.token0);
        assertEq(decoded.token1, original.token1);
        assertEq(decoded.stableDecimals, original.stableDecimals);
        assertEq(decoded.tickSpacing, original.tickSpacing);
        assertEq(decoded.floorFeePips, original.floorFeePips);
        assertEq(decoded.cashFeePips, original.cashFeePips);
        assertEq(decoded.extremeFeePips, original.extremeFeePips);
        assertEq(decoded.periodSeconds, original.periodSeconds);
        assertEq(decoded.emaPeriods, original.emaPeriods);
        assertEq(decoded.idleResetSeconds, original.idleResetSeconds);
        assertEq(decoded.hookFeePercent, original.hookFeePercent);
        assertEq(decoded.enterCashMinVolume, original.enterCashMinVolume);
        assertEq(decoded.enterCashEmaRatioPct, original.enterCashEmaRatioPct);
        assertEq(decoded.holdCashPeriods, original.holdCashPeriods);
        assertEq(decoded.enterExtremeMinVolume, original.enterExtremeMinVolume);
        assertEq(decoded.enterExtremeEmaRatioPct, original.enterExtremeEmaRatioPct);
        assertEq(decoded.enterExtremeConfirmPeriods, original.enterExtremeConfirmPeriods);
        assertEq(decoded.holdExtremePeriods, original.holdExtremePeriods);
        assertEq(decoded.exitExtremeEmaRatioPct, original.exitExtremeEmaRatioPct);
        assertEq(decoded.exitExtremeConfirmPeriods, original.exitExtremeConfirmPeriods);
        assertEq(decoded.exitCashEmaRatioPct, original.exitCashEmaRatioPct);
        assertEq(decoded.exitCashConfirmPeriods, original.exitCashConfirmPeriods);
        assertEq(decoded.lowVolumeReset, original.lowVolumeReset);
        assertEq(decoded.lowVolumeResetPeriods, original.lowVolumeResetPeriods);
    }

    function test_toDeploymentConfig_preserves_constructor_args_encoding() public view {
        OpsTypes.DeploymentConfig memory original = _cfg(address(0xBEEF), 6, V2_INITIAL_HOOK_FEE_PERCENT);
        bytes memory args = HookIdentityLib.constructorArgs(original);
        OpsTypes.DeploymentConfig memory decoded = ConstructorArgsConfigLib.toDeploymentConfig(args);

        assertEq(keccak256(HookIdentityLib.constructorArgs(decoded)), keccak256(args));
    }

    function _cfg(address owner_, uint8 stableDecimals_, uint16 hookFeePercent_)
        internal
        view
        returns (OpsTypes.DeploymentConfig memory cfg)
    {
        cfg.poolManager = address(manager);
        cfg.owner = owner_;
        cfg.token0 = TOKEN0;
        cfg.token1 = TOKEN1;
        cfg.stableToken = TOKEN0;
        cfg.stableDecimals = stableDecimals_;
        cfg.tickSpacing = TICK_SPACING;
        cfg.floorFeePips = V2_DEFAULT_FLOOR_FEE;
        cfg.cashFeePips = V2_DEFAULT_CASH_FEE;
        cfg.extremeFeePips = V2_DEFAULT_EXTREME_FEE;
        cfg.periodSeconds = PERIOD_SECONDS;
        cfg.emaPeriods = EMA_PERIODS;
        cfg.idleResetSeconds = LULL_RESET_SECONDS;
        cfg.hookFeePercent = hookFeePercent_;
        cfg.enterCashMinVolume = V2_FLOOR_TO_CASH_MIN_CLOSE_VOLUME;
        cfg.enterCashEmaRatioPct = V2_FLOOR_TO_CASH_MIN_FLOW_BPS;
        cfg.holdCashPeriods = V2_CASH_HOLD_PERIODS;
        cfg.enterExtremeMinVolume = V2_CASH_TO_EXTREME_MIN_CLOSE_VOLUME;
        cfg.enterExtremeEmaRatioPct = V2_CASH_TO_EXTREME_MIN_FLOW_BPS;
        cfg.enterExtremeConfirmPeriods = V2_CASH_TO_EXTREME_CONFIRM_PERIODS;
        cfg.holdExtremePeriods = V2_EXTREME_HOLD_PERIODS;
        cfg.exitExtremeEmaRatioPct = V2_EXTREME_TO_CASH_MAX_FLOW_BPS;
        cfg.exitExtremeConfirmPeriods = V2_EXTREME_TO_CASH_CONFIRM_PERIODS;
        cfg.exitCashEmaRatioPct = V2_CASH_TO_FLOOR_MAX_FLOW_BPS;
        cfg.exitCashConfirmPeriods = V2_CASH_TO_FLOOR_CONFIRM_PERIODS;
        cfg.lowVolumeReset = V2_EMERGENCY_TO_FLOOR_MAX_CLOSE_VOLUME;
        cfg.lowVolumeResetPeriods = V2_EMERGENCY_TO_FLOOR_CONFIRM_PERIODS;
    }
}
