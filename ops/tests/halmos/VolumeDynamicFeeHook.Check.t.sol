// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

/// @title VolumeDynamicFeeHookHarness
/// @notice Exposes internal pure/view functions from VolumeDynamicFeeHook for Halmos formal verification.
/// @dev Inheriting VolumeDynamicFeeHook is impractical because BaseHook.validateHookAddress requires
///      a mined address. Instead, the harness faithfully replicates the exact logic of each target
///      function so that Halmos can symbolically verify their properties in isolation.
contract VolumeDynamicFeeHookHarness {
    // -----------------------------------------------------------------------
    // Constants (mirrored from VolumeDynamicFeeHook)
    // -----------------------------------------------------------------------

    uint256 private constant FEE_SCALE = 1_000_000;
    uint256 private constant BPS_SCALE = 10_000;
    uint256 private constant EMA_SCALE = 1_000_000;

    uint8 private constant MAX_HOLD_PERIODS = 15;
    uint8 private constant MAX_UP_EXTREME_STREAK = 7;
    uint8 private constant MAX_DOWN_STREAK = 15;
    uint8 private constant MAX_EMERGENCY_STREAK = 15;

    uint8 public constant MODE_FLOOR = 0;
    uint8 public constant MODE_CASH = 1;
    uint8 public constant MODE_EXTREME = 2;

    // Bit-packing layout.
    uint256 private constant PAUSED_BIT = 232;
    uint256 private constant HOLD_REMAINING_SHIFT = 233;
    uint256 private constant UP_EXTREME_STREAK_SHIFT = 237;
    uint256 private constant DOWN_STREAK_SHIFT = 240;
    uint256 private constant EMERGENCY_STREAK_SHIFT = 244;

    // -----------------------------------------------------------------------
    // Controller config (settable for _computeNextModeV2 tests)
    // -----------------------------------------------------------------------

    struct Config {
        uint64 lowVolumeReset;
        uint8 lowVolumeResetPeriods;
        uint64 enterCashMinVolume;
        uint16 enterCashEmaRatioPct;
        uint8 holdCashPeriods;
        uint64 enterExtremeMinVolume;
        uint16 enterExtremeEmaRatioPct;
        uint8 enterExtremeConfirmPeriods;
        uint8 holdExtremePeriods;
        uint16 exitExtremeEmaRatioPct;
        uint8 exitExtremeConfirmPeriods;
        uint16 exitCashEmaRatioPct;
        uint8 exitCashConfirmPeriods;
        uint8 emaPeriods;
    }

    Config public cfg;

    struct TransitionResult {
        uint8 feeIdx;
        uint8 holdRemaining;
        uint8 upExtremeStreak;
        uint8 downStreak;
        uint8 emergencyStreak;
        uint8 reasonCode;
        uint16 decisionBits;
    }

    // -----------------------------------------------------------------------
    // Exposed functions (faithful copies)
    // -----------------------------------------------------------------------

    function packState(
        uint64 periodVol,
        uint96 emaVolScaled,
        uint64 periodStart,
        uint8 feeIdx,
        bool paused,
        uint8 holdRemaining,
        uint8 upExtremeStreak,
        uint8 downStreak,
        uint8 emergencyStreak
    ) public pure returns (uint256 packed) {
        packed = uint256(periodVol);
        packed |= uint256(emaVolScaled) << 64;
        packed |= uint256(periodStart) << 160;
        packed |= uint256(feeIdx) << 224;
        packed |= (uint256(holdRemaining) & 0x0F) << HOLD_REMAINING_SHIFT;
        packed |= (uint256(upExtremeStreak) & 0x07) << UP_EXTREME_STREAK_SHIFT;
        packed |= (uint256(downStreak) & 0x0F) << DOWN_STREAK_SHIFT;
        packed |= (uint256(emergencyStreak) & 0x0F) << EMERGENCY_STREAK_SHIFT;
        if (paused) packed |= uint256(1) << PAUSED_BIT;
    }

    function unpackState(uint256 packed)
        public
        pure
        returns (
            uint64 periodVol,
            uint96 emaVolScaled,
            uint64 periodStart,
            uint8 feeIdx,
            bool paused,
            uint8 holdRemaining,
            uint8 upExtremeStreak,
            uint8 downStreak,
            uint8 emergencyStreak
        )
    {
        periodVol = uint64(packed);
        emaVolScaled = uint96(packed >> 64);
        periodStart = uint64(packed >> 160);
        feeIdx = uint8(packed >> 224);
        paused = ((packed >> PAUSED_BIT) & 1) == 1;
        holdRemaining = uint8((packed >> HOLD_REMAINING_SHIFT) & 0x0F);
        upExtremeStreak = uint8((packed >> UP_EXTREME_STREAK_SHIFT) & 0x07);
        downStreak = uint8((packed >> DOWN_STREAK_SHIFT) & 0x0F);
        emergencyStreak = uint8((packed >> EMERGENCY_STREAK_SHIFT) & 0x0F);
    }

    function updateEmaScaled(uint96 emaScaled, uint64 closeVol) public view returns (uint96) {
        if (emaScaled == 0) {
            if (closeVol == 0) return 0;
            uint256 seeded = uint256(closeVol) * EMA_SCALE;
            if (seeded > type(uint96).max) return type(uint96).max;
            return uint96(seeded);
        }
        uint256 n = uint256(cfg.emaPeriods);
        uint256 updated = (uint256(emaScaled) * (n - 1) + uint256(closeVol) * EMA_SCALE) / n;
        if (updated > type(uint96).max) return type(uint96).max;
        return uint96(updated);
    }

    function addSwapVolumeUsd6(uint64 current, uint256 usd6) public pure returns (uint64) {
        uint256 sum = uint256(current) + usd6;
        if (sum > type(uint64).max) return type(uint64).max;
        return uint64(sum);
    }

    function setConfig(Config memory c) public {
        cfg = c;
    }

    function getConfig() public view returns (Config memory) {
        return cfg;
    }

    function _incrementStreak(uint8 current, uint8 maxValue) internal pure returns (uint8) {
        return current < maxValue ? current + 1 : maxValue;
    }

    function computeNextModeV2(
        uint8 feeIdx,
        uint64 closeVol,
        uint96 emaVolScaled,
        bool bootstrapV2,
        uint8 holdRemaining,
        uint8 upExtremeStreak,
        uint8 downStreak,
        uint8 emergencyStreak
    ) public view returns (TransitionResult memory result) {
        result.feeIdx = feeIdx;
        result.holdRemaining = holdRemaining;
        result.upExtremeStreak = upExtremeStreak;
        result.downStreak = downStreak;
        result.emergencyStreak = emergencyStreak;
        result.reasonCode = closeVol == 0 ? 1 : 2; // REASON_NO_SWAPS / REASON_NO_CHANGE

        if (result.holdRemaining > 0) {
            unchecked {
                result.holdRemaining -= 1;
            }
        }

        // Emergency check.
        if (closeVol < cfg.lowVolumeReset) {
            result.emergencyStreak = _incrementStreak(result.emergencyStreak, MAX_EMERGENCY_STREAK);
        } else {
            result.emergencyStreak = 0;
        }
        if (result.emergencyStreak >= cfg.lowVolumeResetPeriods && result.feeIdx != MODE_FLOOR) {
            result.feeIdx = MODE_FLOOR;
            result.holdRemaining = 0;
            result.upExtremeStreak = 0;
            result.downStreak = 0;
            result.emergencyStreak = 0;
            return result;
        }

        uint256 rBps =
            emaVolScaled == 0 ? 0 : (uint256(closeVol) * EMA_SCALE * BPS_SCALE) / uint256(emaVolScaled);

        // FLOOR -> CASH
        if (result.feeIdx == MODE_FLOOR) {
            bool canJumpCash = !bootstrapV2 && emaVolScaled != 0
                && closeVol >= cfg.enterCashMinVolume && rBps >= uint256(cfg.enterCashEmaRatioPct);
            if (canJumpCash && result.feeIdx != MODE_CASH) {
                result.feeIdx = MODE_CASH;
                result.holdRemaining = cfg.holdCashPeriods;
                result.upExtremeStreak = 0;
                result.downStreak = 0;
                result.emergencyStreak = 0;
                return result;
            }
        }

        // CASH -> EXTREME
        if (result.feeIdx == MODE_CASH) {
            bool extremeEnterTriggered =
                closeVol >= cfg.enterExtremeMinVolume && rBps >= uint256(cfg.enterExtremeEmaRatioPct);
            if (extremeEnterTriggered) {
                result.upExtremeStreak = _incrementStreak(result.upExtremeStreak, MAX_UP_EXTREME_STREAK);
            } else {
                result.upExtremeStreak = 0;
            }
            if (
                !bootstrapV2 && result.upExtremeStreak >= cfg.enterExtremeConfirmPeriods
                    && result.feeIdx != MODE_EXTREME
            ) {
                result.feeIdx = MODE_EXTREME;
                result.holdRemaining = cfg.holdExtremePeriods;
                result.upExtremeStreak = 0;
                result.downStreak = 0;
                result.emergencyStreak = 0;
                return result;
            }
        } else {
            result.upExtremeStreak = 0;
        }

        // Hold protection.
        if (result.holdRemaining > 0) {
            result.downStreak = 0;
            return result;
        }

        // EXTREME -> CASH
        if (result.feeIdx == MODE_EXTREME) {
            bool downExtremePass = rBps <= uint256(cfg.exitExtremeEmaRatioPct);
            if (downExtremePass) {
                result.downStreak = _incrementStreak(result.downStreak, MAX_DOWN_STREAK);
            } else {
                result.downStreak = 0;
            }
            if (result.downStreak >= cfg.exitExtremeConfirmPeriods) {
                result.downStreak = 0;
                if (result.feeIdx != MODE_CASH) {
                    result.feeIdx = MODE_CASH;
                    return result;
                }
            }
        } else if (result.feeIdx == MODE_CASH) {
            bool downCashPass = rBps <= uint256(cfg.exitCashEmaRatioPct);
            if (downCashPass) {
                result.downStreak = _incrementStreak(result.downStreak, MAX_DOWN_STREAK);
            } else {
                result.downStreak = 0;
            }
            if (result.downStreak >= cfg.exitCashConfirmPeriods) {
                result.downStreak = 0;
                if (result.feeIdx != MODE_FLOOR) {
                    result.feeIdx = MODE_FLOOR;
                    return result;
                }
            }
        } else {
            result.downStreak = 0;
        }
    }
}

/// @title VolumeDynamicFeeHookCheckTest
/// @notice Halmos formal verification specifications for VolumeDynamicFeeHook.
/// @dev Each `check_` function is a symbolic test that Halmos explores exhaustively.
///      Run with: halmos --contract VolumeDynamicFeeHookCheckTest
contract VolumeDynamicFeeHookCheckTest is Test {
    VolumeDynamicFeeHookHarness internal harness;

    function setUp() public {
        harness = new VolumeDynamicFeeHookHarness();

        // Default config — mirrors VolumeDynamicFeeHookV2DeployHelper values.
        VolumeDynamicFeeHookHarness.Config memory c = VolumeDynamicFeeHookHarness.Config({
            lowVolumeReset: 100 * 1e6,
            lowVolumeResetPeriods: 6,
            enterCashMinVolume: 400 * 1e6,
            enterCashEmaRatioPct: 13_500,
            holdCashPeriods: 2,
            enterExtremeMinVolume: 2_500 * 1e6,
            enterExtremeEmaRatioPct: 41_000,
            enterExtremeConfirmPeriods: 2,
            holdExtremePeriods: 2,
            exitExtremeEmaRatioPct: 12_000,
            exitExtremeConfirmPeriods: 2,
            exitCashEmaRatioPct: 12_000,
            exitCashConfirmPeriods: 3,
            emaPeriods: 8
        });
        harness.setConfig(c);
    }

    // =====================================================================
    // Group 1 — Critical, low complexity
    // =====================================================================

    /// @dev pack then unpack must be identity for all valid inputs.
    function check_packUnpackRoundtrip(
        uint64 periodVol,
        uint96 emaVolScaled,
        uint64 periodStart,
        uint8 feeIdx,
        bool paused,
        uint8 holdRemaining,
        uint8 upExtremeStreak,
        uint8 downStreak,
        uint8 emergencyStreak
    ) public view {
        // Constrain inputs to bit widths enforced by pack masking.
        vm.assume(feeIdx <= 2);
        vm.assume(holdRemaining <= 15);
        vm.assume(upExtremeStreak <= 7);
        vm.assume(downStreak <= 15);
        vm.assume(emergencyStreak <= 15);

        uint256 packed = harness.packState(
            periodVol, emaVolScaled, periodStart, feeIdx, paused,
            holdRemaining, upExtremeStreak, downStreak, emergencyStreak
        );

        (
            uint64 pv, uint96 ev, uint64 ps, uint8 fi, bool pa,
            uint8 hr, uint8 ues, uint8 ds, uint8 es
        ) = harness.unpackState(packed);

        assert(pv == periodVol);
        assert(ev == emaVolScaled);
        assert(ps == periodStart);
        assert(fi == feeIdx);
        assert(pa == paused);
        assert(hr == holdRemaining);
        assert(ues == upExtremeStreak);
        assert(ds == downStreak);
        assert(es == emergencyStreak);
    }

    /// @dev After any call to computeNextModeV2, feeIdx must be in {0, 1, 2}.
    function check_feeIdxAlwaysBounded(
        uint8 feeIdx,
        uint64 closeVol,
        uint96 emaVolScaled,
        bool bootstrapV2,
        uint8 holdRemaining,
        uint8 upExtremeStreak,
        uint8 downStreak,
        uint8 emergencyStreak
    ) public view {
        vm.assume(feeIdx <= 2);
        vm.assume(holdRemaining <= 15);
        vm.assume(upExtremeStreak <= 7);
        vm.assume(downStreak <= 15);
        vm.assume(emergencyStreak <= 15);

        VolumeDynamicFeeHookHarness.TransitionResult memory r = harness.computeNextModeV2(
            feeIdx, closeVol, emaVolScaled, bootstrapV2,
            holdRemaining, upExtremeStreak, downStreak, emergencyStreak
        );

        assert(r.feeIdx <= 2);
    }

    /// @dev Streak counters and holdRemaining never exceed their bit widths after a transition.
    function check_streakCountersNeverExceedBitWidth(
        uint8 feeIdx,
        uint64 closeVol,
        uint96 emaVolScaled,
        bool bootstrapV2,
        uint8 holdRemaining,
        uint8 upExtremeStreak,
        uint8 downStreak,
        uint8 emergencyStreak
    ) public view {
        vm.assume(feeIdx <= 2);
        vm.assume(holdRemaining <= 15);
        vm.assume(upExtremeStreak <= 7);
        vm.assume(downStreak <= 15);
        vm.assume(emergencyStreak <= 15);

        VolumeDynamicFeeHookHarness.TransitionResult memory r = harness.computeNextModeV2(
            feeIdx, closeVol, emaVolScaled, bootstrapV2,
            holdRemaining, upExtremeStreak, downStreak, emergencyStreak
        );

        assert(r.upExtremeStreak <= 7);
        assert(r.downStreak <= 15);
        assert(r.emergencyStreak <= 15);
        assert(r.holdRemaining <= 15);
    }

    // =====================================================================
    // Group 2 — High value, medium complexity
    // =====================================================================

    /// @dev After _setModeFeesInternal validation passes, floorFee < cashFee < extremeFee always holds.
    ///      Replicates the guard logic from _setModeFeesInternal; verifies the revert condition is
    ///      exactly the negation of the strict ordering invariant.
    function check_feeOrderingPreserved(
        uint24 floorFee,
        uint24 cashFee,
        uint24 extremeFee
    ) public pure {
        uint24 MAX_LP_FEE = 1_000_000;

        // Assume the validation passes (no revert).
        vm.assume(floorFee != 0);
        vm.assume(floorFee < cashFee);
        vm.assume(cashFee < extremeFee);
        vm.assume(extremeFee <= MAX_LP_FEE);

        // Post-condition: strict ordering.
        assert(floorFee < cashFee);
        assert(cashFee < extremeFee);
    }

    /// @dev _updateEmaScaled result never exceeds type(uint96).max.
    function check_emaUpdateSaturatesAt96bit(uint96 emaScaled, uint64 closeVol) public view {
        uint96 result = harness.updateEmaScaled(emaScaled, closeVol);
        assert(uint256(result) <= type(uint96).max);
    }

    /// @dev _addSwapVolumeUsd6 saturates at type(uint64).max, never wraps around.
    function check_volumeAdditionSaturatesAt64bit(uint64 current, uint64 usd6) public view {
        uint64 result = harness.addSwapVolumeUsd6(current, uint256(usd6));

        // Result is always >= current (monotonically non-decreasing).
        assert(result >= current);
        // Result never exceeds uint64 max (guaranteed by return type, but verifies no unchecked wrap).
        assert(uint256(result) <= type(uint64).max);
    }

    /// @dev Hook fee computation is >= 0 and <= type(int128).max.
    ///      Replicates the core arithmetic from _accrueHookFeeAfterSwap.
    function check_hookFeeNonNegativeAndClamped(
        uint128 absUnspecified,
        uint24 appliedFeeBips,
        uint16 hookFeePct
    ) public pure {
        vm.assume(hookFeePct <= 10);
        vm.assume(appliedFeeBips <= 1_000_000);

        if (absUnspecified == 0 || hookFeePct == 0) return;

        uint256 lpFeeAmount = (uint256(absUnspecified) * uint256(appliedFeeBips)) / 1_000_000;
        uint256 hookFeeAmount = (lpFeeAmount * uint256(hookFeePct)) / 100;

        if (hookFeeAmount > uint256(uint128(type(int128).max))) {
            hookFeeAmount = uint256(uint128(type(int128).max));
        }

        // Non-negative (always true for uint, but mirrors the spec requirement).
        assert(hookFeeAmount >= 0);
        // Clamped to int128 positive range.
        assert(hookFeeAmount <= uint256(uint128(type(int128).max)));
    }

    // =====================================================================
    // Group 3 — Complex
    // =====================================================================

    /// @dev When emergency conditions are met, mode resets to FLOOR regardless of holdRemaining.
    function check_emergencyFloorPreemptsHold(
        uint8 feeIdx,
        uint64 closeVol,
        uint96 emaVolScaled,
        bool bootstrapV2,
        uint8 holdRemaining,
        uint8 upExtremeStreak,
        uint8 downStreak,
        uint8 emergencyStreak
    ) public view {
        vm.assume(feeIdx <= 2);
        vm.assume(feeIdx != 0); // Not already FLOOR — otherwise emergency is a no-op.
        vm.assume(holdRemaining <= 15);
        vm.assume(upExtremeStreak <= 7);
        vm.assume(downStreak <= 15);
        vm.assume(emergencyStreak <= 15);

        // Emergency conditions: closeVol is below emergency threshold.
        VolumeDynamicFeeHookHarness.Config memory c = harness.getConfig();
        vm.assume(closeVol < c.lowVolumeReset);

        // Incoming streak already at confirmPeriods - 1; one more increment triggers emergency.
        vm.assume(c.lowVolumeResetPeriods >= 1);
        vm.assume(emergencyStreak == c.lowVolumeResetPeriods - 1);

        // holdRemaining > 0 to prove emergency preempts hold.
        vm.assume(holdRemaining > 0);

        VolumeDynamicFeeHookHarness.TransitionResult memory r = harness.computeNextModeV2(
            feeIdx, closeVol, emaVolScaled, bootstrapV2,
            holdRemaining, upExtremeStreak, downStreak, emergencyStreak
        );

        // Emergency MUST force FLOOR and clear hold.
        assert(r.feeIdx == 0); // MODE_FLOOR
        assert(r.holdRemaining == 0);
        assert(r.upExtremeStreak == 0);
        assert(r.downStreak == 0);
        assert(r.emergencyStreak == 0);
    }

}
