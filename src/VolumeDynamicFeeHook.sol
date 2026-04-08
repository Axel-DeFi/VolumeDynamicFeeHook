// SPDX-License-Identifier: LicenseRef-Audit-Only-Source-Available-1.0
pragma solidity ^0.8.26;

import {BaseHook} from "@uniswap/v4-hooks-public/src/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

/// @title VolumeDynamicFeeHook
/// @notice Single-pool Uniswap v4 hook that manages dynamic LP fees.
/// @notice Source code, documentation, and audit reports live at https://github.com/Axel-DeFi/VolumeDynamicFeeHook.
/// @dev NatSpec in this file is the source of truth for operations docs.
contract VolumeDynamicFeeHook is BaseHook, IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;

    // -----------------------------------------------------------------------
    // Constants
    // -----------------------------------------------------------------------

    /// @notice Fixed-point scale used by Uniswap LP fee tiers (1e6 = 100%).
    uint256 private constant FEE_SCALE = 1_000_000;

    /// @notice Basis-point scale used for percentage math.
    uint256 private constant BPS_SCALE = 10_000;

    /// @notice Scaler used for EMA precision. Stored EMA units are USD6 * EMA_SCALE.
    uint256 private constant EMA_SCALE = 1_000_000;

    /// @notice Hard maximum for the hook fee percent used by the hook settlement formula.
    uint16 public constant MAX_HOOK_FEE_PERCENT = 10;

    /// @notice Maximum single settlement amount accepted by PoolManager burn/take accounting.
    uint256 private constant MAX_POOLMANAGER_SETTLEMENT_AMOUNT = uint256(uint128(type(int128).max));

    /// @notice Timelock delay for hook fee percent parameter changes.
    uint64 public constant HOOK_FEE_PERCENT_CHANGE_DELAY = 48 hours;

    /// @notice Default minimum swap notional counted into period volume telemetry.
    uint64 public constant DEFAULT_DUST_SWAP_THRESHOLD = 4_000_000;

    /// @notice Minimum allowed dust-swap threshold (USD6).
    uint64 public constant MIN_DUST_SWAP_THRESHOLD = 1_000_000;

    /// @notice Maximum allowed dust-swap threshold (USD6).
    uint64 public constant MAX_DUST_SWAP_THRESHOLD = 10_000_000;

    uint16 private constant MAX_LULL_PERIODS = 24;
    uint8 private constant MAX_EMA_PERIODS = 128;
    uint8 private constant MAX_HOLD_PERIODS = 15;
    uint8 private constant MAX_UP_EXTREME_STREAK = 7;
    uint8 private constant MAX_DOWN_STREAK = 15;
    uint8 private constant MAX_EMERGENCY_STREAK = 15;

    uint8 public constant MODE_FLOOR = 0;
    uint8 public constant MODE_CASH = 1;
    uint8 public constant MODE_EXTREME = 2;

    // Period-close reason codes.
    uint8 public constant REASON_NO_SWAPS = 7;
    uint8 public constant REASON_IDLE_RESET = 8;
    uint8 public constant REASON_EMA_BOOTSTRAP = 10;
    uint8 public constant REASON_JUMP_CASH = 11;
    uint8 public constant REASON_JUMP_EXTREME = 12;
    uint8 public constant REASON_DOWN_TO_CASH = 13;
    uint8 public constant REASON_DOWN_TO_FLOOR = 14;
    uint8 public constant REASON_HOLD = 15;
    uint8 public constant REASON_EMERGENCY_FLOOR = 16;
    uint8 public constant REASON_NO_CHANGE = 17;

    // Packed-state layout.
    uint256 private constant PAUSED_BIT = 232;
    uint256 private constant HOLD_REMAINING_SHIFT = 233; // bits 233..236
    uint256 private constant UP_EXTREME_STREAK_SHIFT = 237; // bits 237..239
    uint256 private constant DOWN_STREAK_SHIFT = 240; // bits 240..243
    uint256 private constant EMERGENCY_STREAK_SHIFT = 244; // bits 244..247

    // Compact trace counter packing layout.
    uint8 private constant TRACE_COUNTER_HOLD_SHIFT = 1;
    uint8 private constant TRACE_COUNTER_UP_EXTREME_SHIFT = 5;
    uint8 private constant TRACE_COUNTER_DOWN_SHIFT = 8;
    uint8 private constant TRACE_COUNTER_EMERGENCY_SHIFT = 12;

    // Compact trace decision flags.
    uint16 private constant TRACE_FLAG_BOOTSTRAP_V2 = 0x0001;
    uint16 private constant TRACE_FLAG_HOLD_WAS_ACTIVE = 0x0004;
    uint16 private constant TRACE_FLAG_EMERGENCY_TRIGGERED = 0x0008;
    uint16 private constant TRACE_FLAG_CASH_ENTER_TRIGGER = 0x0010;
    uint16 private constant TRACE_FLAG_EXTREME_ENTER_TRIGGER = 0x0020;
    uint16 private constant TRACE_FLAG_EXTREME_EXIT_TRIGGER = 0x0040;
    uint16 private constant TRACE_FLAG_CASH_EXIT_TRIGGER = 0x0080;

    // -----------------------------------------------------------------------
    // Types
    // -----------------------------------------------------------------------

    struct HookFeeClaimUnlockData {
        address recipient;
        uint256 amount0;
        uint256 amount1;
    }

    /// @notice Mutable controller and fee configuration.
    /// @dev Every `*Volume` field is expressed in USD using the internal 6-decimal scale.
    struct ControllerConfig {
        uint24 floorFee;
        uint24 cashFee;
        uint24 extremeFee;
        uint64 enterCashMinVolume;
        uint64 enterExtremeMinVolume;
        uint64 lowVolumeReset;
        uint64 dustSwapThreshold;
        uint32 periodSeconds;
        uint32 idleResetSeconds;
        uint16 enterCashEmaRatioPct;
        uint16 enterExtremeEmaRatioPct;
        uint16 exitExtremeEmaRatioPct;
        uint16 exitCashEmaRatioPct;
        uint16 hookFeePercent;
        uint8 emaPeriods;
        uint8 holdCashPeriods;
        uint8 enterExtremeConfirmPeriods;
        uint8 holdExtremePeriods;
        uint8 exitExtremeConfirmPeriods;
        uint8 exitCashConfirmPeriods;
        uint8 lowVolumeResetPeriods;
    }

    /// @notice Runtime state-machine transition parameters passed to `setControllerSettings`.
    /// @dev Every `*Volume` field is expressed in USD using the internal 6-decimal scale.
    /// @dev Reset-group fields (`idleResetSeconds`, `lowVolumeReset`, `lowVolumeResetPeriods`) are managed
    ///      separately via `setResetSettings` and are not part of this struct.
    struct ControllerSettings {
        /// @dev minimum period volume required to consider entering cash mode
        uint64 enterCashMinVolume;
        /// @dev minimum current-period-to-EMA ratio, in percent, required to enter cash mode
        uint16 enterCashEmaRatioPct;
        // Configured hold length N; hold only blocks the ordinary cash->floor path, while the emergency path keeps
        // accumulating. Effective fully protected periods are N - 1, so the earliest ordinary cash->floor close under
        // uninterrupted weakness is `holdCashPeriods + exitCashConfirmPeriods - 1`.
        /// @dev number of periods to hold cash mode after entry
        uint8 holdCashPeriods;
        /// @dev minimum period volume required to consider entering extreme mode
        uint64 enterExtremeMinVolume;
        /// @dev minimum current-period-to-EMA ratio, in percent, required to enter extreme mode
        uint16 enterExtremeEmaRatioPct;
        /// @dev number of strong periods required to confirm entry into extreme mode
        uint8 enterExtremeConfirmPeriods;
        // Same semantics as cash hold: hold only blocks the ordinary extreme->cash path, emergency still advances, and
        // the earliest ordinary extreme->cash close under uninterrupted weakness is
        // `holdExtremePeriods + exitExtremeConfirmPeriods - 1`.
        /// @dev number of periods to hold extreme mode after entry
        uint8 holdExtremePeriods;
        /// @dev maximum current-period-to-EMA ratio, in percent, below which extreme mode may exit
        uint16 exitExtremeEmaRatioPct;
        /// @dev number of weak periods required to confirm exit from extreme mode
        uint8 exitExtremeConfirmPeriods;
        /// @dev maximum current-period-to-EMA ratio, in percent, below which cash mode may exit
        uint16 exitCashEmaRatioPct;
        /// @dev number of weak periods required to confirm exit from cash mode
        uint8 exitCashConfirmPeriods;
    }

    struct ControllerTransitionResult {
        uint8 feeIdx;
        uint8 holdRemaining;
        uint8 upExtremeStreak;
        uint8 downStreak;
        uint8 emergencyStreak;
        uint8 reasonCode;
        uint16 decisionBits;
    }

    struct PeriodTrace {
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

    /// @notice Working context for the `_afterSwap` orchestrator.
    /// @dev Holds unpacked state fields and per-call temporaries to reduce stack depth
    ///      and enable clean decomposition into helper functions.
    struct AfterSwapCtx {
        uint64 periodVol;
        uint96 emaVolScaled;
        uint64 periodStart;
        uint8 feeIdx;
        bool paused;
        uint8 holdRemaining;
        uint8 upExtremeStreak;
        uint8 downStreak;
        uint8 emergencyStreak;
        uint24 appliedFee;
        uint64 nowTs;
        uint64 elapsed;
        bool feeChanged;
        uint64 closeVolForEvent;
        int128 hookFeeDelta;
    }

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    /// @notice Emitted when active LP fee tier changes.
    event FeeUpdated(uint24 fee, uint8 feeIdx, uint64 periodVolume, uint96 emaVolumeScaled);

    /// @notice Emitted for each period-close transition.
    event PeriodClosed(
        uint24 fromFee,
        uint8 fromFeeIdx,
        uint24 toFee,
        uint8 toFeeIdx,
        uint64 periodVolume,
        uint96 emaVolumeScaled,
        uint64 approxLpFeesUsd,
        uint8 reasonCode
    );

    /// @notice Emitted alongside `PeriodClosed` with compact controller diagnostics for the closed period.
    /// @dev `stateBitsBefore` / `stateBitsAfter` pack:
    /// bit 0 paused, bits 1..4 holdRemaining, bits 5..7 upExtremeStreak, bits 8..11 downStreak,
    /// bits 12..15 emergencyStreak.
    /// @dev `decisionBits` packs:
    /// bit 0 bootstrapV2, bit 2 holdWasActive, bit 3 emergencyTriggered,
    /// bit 4 cashEnterTrigger, bit 5 extremeEnterTrigger, bit 6 extremeExitTrigger, bit 7 cashExitTrigger.
    event ControllerTransitionTrace(
        uint64 periodStart,
        uint24 fromFee,
        uint8 fromFeeIdx,
        uint24 toFee,
        uint8 toFeeIdx,
        uint64 periodVolume,
        uint96 emaVolumeBefore,
        uint96 emaVolumeAfter,
        uint64 approxLpFeesUsd,
        uint16 decisionBits,
        uint16 stateBitsBefore,
        uint16 stateBitsAfter,
        uint8 reasonCode
    );

    /// @notice Emitted when the controller is paused in freeze mode.
    event Paused(uint24 fee, uint8 feeIdx);

    /// @notice Emitted when the controller is resumed from freeze mode.
    event Unpaused(uint24 fee, uint8 feeIdx);

    /// @notice Emitted when idle reset triggers due to inactivity.
    event IdleReset(uint24 fee, uint8 feeIdx);

    /// @notice Emitted when accrued HookFees are claimed.
    event HookFeesClaimed(address indexed to, uint256 amount0, uint256 amount1);

    /// @notice Emitted when owner changes.
    event OwnerUpdated(address indexed previousOwner, address indexed newOwner);

    /// @notice Emitted when owner transfer is proposed.
    event OwnerTransferStarted(address indexed currentOwner, address indexed pendingOwner);

    /// @notice Emitted when pending owner transfer is cancelled.
    event OwnerTransferCancelled(address indexed cancelledPendingOwner);

    /// @notice Emitted when pending owner accepts ownership.
    event OwnerTransferAccepted(address indexed previousOwner, address indexed newOwner);

    /// @notice Emitted when explicit mode fees are updated.
    event ModeFeesUpdated(uint24 floorFee, uint24 cashFee, uint24 extremeFee);

    /// @notice Emitted when controller transition parameters are updated.
    event ControllerSettingsUpdated(
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
        uint8 exitCashConfirmPeriods
    );

    /// @notice Emitted when model parameters (period length and EMA denominator) are updated.
    event ModelUpdated(uint32 periodSeconds, uint8 emaPeriods);

    /// @notice Emitted when reset and protective-logic parameters are updated.
    event ResetSettingsUpdated(uint32 idleResetSeconds, uint64 lowVolumeReset, uint8 lowVolumeResetPeriods);

    /// @notice Emitted when a hook fee percent change is scheduled through timelock.
    event HookFeeChangeScheduled(uint16 newHookFee, uint64 executeAfter);

    /// @notice Emitted when scheduled hook fee percent change is cancelled.
    event HookFeeChangeCancelled(uint16 cancelledHookFee);

    /// @notice Emitted when hook fee percent is executed and applied.
    event HookFeeChanged(uint16 oldHookFee, uint16 newHookFee);

    /// @notice Emitted when a dust-swap threshold update is scheduled.
    event DustSwapThresholdChangeScheduled(uint64 newDustSwapThreshold);

    /// @notice Emitted when scheduled dust-swap threshold update is cancelled.
    event DustSwapThresholdChangeCancelled(uint64 cancelledDustSwapThreshold);

    /// @notice Emitted when dust-swap threshold is applied.
    event DustSwapThresholdChanged(uint64 oldDustSwapThreshold, uint64 newDustSwapThreshold);

    /// @notice Emitted when paused emergency reset sets controller to floor mode.
    event EmergencyResetToFloorApplied(uint8 feeIdx, uint64 periodStart, uint96 emaVolumeScaled);

    /// @notice Emitted when paused emergency reset sets controller to cash mode.
    event EmergencyResetToCashApplied(uint8 feeIdx, uint64 periodStart, uint96 emaVolumeScaled);

    /// @notice Emitted when non-pool assets or ETH are rescued.
    event RescueTransfer(address indexed currency, uint256 amount, address indexed recipient);

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    error InvalidPoolKey();
    error NotDynamicFeePool();
    error AlreadyInitialized();
    error NotInitialized();
    error InvalidConfig();
    error InvalidStableDecimals(uint8 stableDecimals);
    error InvalidHoldPeriods();
    error InvalidConfirmPeriods();
    error RequiresPaused();

    error NotOwner();
    error InvalidOwner();
    error PendingOwnerExists();
    error NoPendingOwnerTransfer();
    error NotPendingOwner();

    error InvalidRescueCurrency();
    error InvalidRecipient();
    error ClaimTooLarge();
    error EthTransferFailed();
    error EthReceiveRejected();
    error HookFeePercentLimitExceeded(uint16 requestedPercent, uint16 maxAllowedPercent);
    error PendingHookFeePercentChangeExists();
    error NoPendingHookFeePercentChange();
    error HookFeePercentChangeNotReady(uint64 executeAfter);

    error InvalidDustSwapThreshold();
    error PendingDustSwapThresholdChangeExists();
    error NoPendingDustSwapThresholdChange();

    error InvalidUnlockData();

    // -----------------------------------------------------------------------
    // Storage
    // -----------------------------------------------------------------------

    ControllerConfig private _config;

    address private _owner;
    address private _pendingOwner;

    bool private _hasPendingHookFeePercentChange;
    uint16 private _pendingHookFeePercent;
    uint64 private _pendingHookFeePercentExecuteAfter;

    bool private _hasPendingDustSwapThresholdChange;
    uint64 private _pendingDustSwapThreshold;

    // Packed controller state.
    uint256 private _state;

    // HookFee accrual balances by pool currency order.
    uint256 private _hookFees0;
    uint256 private _hookFees1;

    // -----------------------------------------------------------------------
    // Immutable pool binding
    // -----------------------------------------------------------------------

    /// @notice Bound pool currency0.
    Currency public immutable poolCurrency0;

    /// @notice Bound pool currency1.
    Currency public immutable poolCurrency1;

    /// @notice Bound pool tick spacing.
    int24 public immutable poolTickSpacing;

    /// @notice Stable-side token used for USD6 volume telemetry.
    Currency public immutable stableCurrency;

    /// @notice Configured decimals mode for stable-side telemetry scaling.
    uint8 public immutable stableDecimals;

    bool internal immutable _stableIsCurrency0;
    uint64 internal immutable _stableScale;

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    /// @notice Deploys and configures a single-pool dynamic-fee hook.
    /// @param _poolManager Uniswap v4 PoolManager.
    /// @param _poolCurrency0 Pool currency0 (must be address-sorted and lower than currency1).
    /// @param _poolCurrency1 Pool currency1.
    /// @param _poolTickSpacing Pool tick spacing.
    /// @param _stableCurrency Stable-side token used for volume telemetry.
    /// @param stableDecimals_ Stable token decimals; only `6` or `18` are accepted.
    /// @param _floorFee Floor LP fee in hundredths of a bip.
    /// @param _cashFee Cash LP fee in hundredths of a bip.
    /// @param _extremeFee Extreme LP fee in hundredths of a bip.
    /// @param _periodSeconds Period length in seconds.
    /// @param _emaPeriods EMA denominator.
    /// @param _idleResetSeconds Idle-reset inactivity threshold in seconds. Must be strictly greater than `_periodSeconds`.
    /// @param ownerAddr Initial owner address.
    /// @param hookFeePercent_ Initial hook fee percent used by the hook settlement formula.
    /// @param _enterCashMinVolume Minimum close volume for floor->cash transition.
    /// @param _enterCashEmaRatioPct Close-volume trigger for floor->cash transition, as `closeVol / EMA` in bps.
    /// @param _holdCashPeriods Configured cash hold length `N`. Hold blocks only the ordinary cash->floor path, emergency
    /// still counts, effective fully protected periods are `N - 1`, and the earliest ordinary cash->floor close under
    /// uninterrupted weakness is `holdCashPeriods + exitCashConfirmPeriods - 1`.
    /// @param _enterExtremeMinVolume Minimum close volume for cash->extreme transition.
    /// @param _enterExtremeEmaRatioPct Close-volume trigger for cash->extreme transition, as `closeVol / EMA` in bps.
    /// @param _enterExtremeConfirmPeriods Confirmation periods for cash->extreme transition.
    /// @param _holdExtremePeriods Hold periods after entering extreme. Hold blocks only the ordinary extreme->cash path,
    /// emergency still counts, and the earliest ordinary extreme->cash close under uninterrupted weakness is
    /// `holdExtremePeriods + exitExtremeConfirmPeriods - 1`.
    /// @param _exitExtremeEmaRatioPct Close-volume trigger ceiling for extreme->cash transition, as `closeVol / EMA` in bps.
    /// @param _exitExtremeConfirmPeriods Confirmation periods for extreme->cash transition.
    /// @param _exitCashEmaRatioPct Close-volume trigger ceiling for cash->floor transition, as `closeVol / EMA` in bps.
    /// @param _exitCashConfirmPeriods Confirmation periods for cash->floor transition.
    /// @param _lowVolumeReset Emergency floor trigger threshold (`> 0` and strictly below `_enterCashMinVolume`).
    /// @param _lowVolumeResetPeriods Consecutive confirmations for emergency floor trigger. The earliest
    /// emergency descent under uninterrupted weakness is `lowVolumeResetPeriods`.
    constructor(
        IPoolManager _poolManager,
        Currency _poolCurrency0,
        Currency _poolCurrency1,
        int24 _poolTickSpacing,
        Currency _stableCurrency,
        uint8 stableDecimals_,
        uint24 _floorFee,
        uint24 _cashFee,
        uint24 _extremeFee,
        uint32 _periodSeconds,
        uint8 _emaPeriods,
        uint32 _idleResetSeconds,
        address ownerAddr,
        uint16 hookFeePercent_,
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
    ) BaseHook(_poolManager) {
        if (address(_poolManager) == address(0)) revert InvalidConfig();

        // Enforce canonical pool token ordering.
        if (Currency.unwrap(_poolCurrency0) >= Currency.unwrap(_poolCurrency1)) revert InvalidConfig();
        if (_poolTickSpacing <= 0) revert InvalidConfig();

        poolCurrency0 = _poolCurrency0;
        poolCurrency1 = _poolCurrency1;
        poolTickSpacing = _poolTickSpacing;

        if (!(_stableCurrency == _poolCurrency0) && !(_stableCurrency == _poolCurrency1)) {
            revert InvalidConfig();
        }
        stableCurrency = _stableCurrency;
        _stableIsCurrency0 = (_stableCurrency == _poolCurrency0);

        if (stableDecimals_ != 6 && stableDecimals_ != 18) {
            revert InvalidStableDecimals(stableDecimals_);
        }
        stableDecimals = stableDecimals_;

        if (stableDecimals_ == 6) _stableScale = 1;
        else _stableScale = 1_000_000_000_000;

        _setModelInternal(_periodSeconds, _emaPeriods);
        _setOwnerInternal(ownerAddr);
        _setHookFeePercentInternal(hookFeePercent_);
        _setModeFeesInternal(_floorFee, _cashFee, _extremeFee);

        ControllerSettings memory p = ControllerSettings({
            enterCashMinVolume: _enterCashMinVolume,
            enterCashEmaRatioPct: _enterCashEmaRatioPct,
            holdCashPeriods: _holdCashPeriods,
            enterExtremeMinVolume: _enterExtremeMinVolume,
            enterExtremeEmaRatioPct: _enterExtremeEmaRatioPct,
            enterExtremeConfirmPeriods: _enterExtremeConfirmPeriods,
            holdExtremePeriods: _holdExtremePeriods,
            exitExtremeEmaRatioPct: _exitExtremeEmaRatioPct,
            exitExtremeConfirmPeriods: _exitExtremeConfirmPeriods,
            exitCashEmaRatioPct: _exitCashEmaRatioPct,
            exitCashConfirmPeriods: _exitCashConfirmPeriods
        });
        _setControllerSettingsInternal(p);
        _setResetSettingsInternal(_idleResetSeconds, _lowVolumeReset, _lowVolumeResetPeriods);

        _config.dustSwapThreshold = DEFAULT_DUST_SWAP_THRESHOLD;

        emit OwnerUpdated(address(0), ownerAddr);
        emit HookFeeChanged(0, hookFeePercent_);
        emit ModeFeesUpdated(_floorFee, _cashFee, _extremeFee);
        emit ControllerSettingsUpdated(
            p.enterCashMinVolume,
            p.enterCashEmaRatioPct,
            p.holdCashPeriods,
            p.enterExtremeMinVolume,
            p.enterExtremeEmaRatioPct,
            p.enterExtremeConfirmPeriods,
            p.holdExtremePeriods,
            p.exitExtremeEmaRatioPct,
            p.exitExtremeConfirmPeriods,
            p.exitCashEmaRatioPct,
            p.exitCashConfirmPeriods
        );
        emit ModelUpdated(_config.periodSeconds, _config.emaPeriods);
        emit ResetSettingsUpdated(_config.idleResetSeconds, _config.lowVolumeReset, _config.lowVolumeResetPeriods);
        emit DustSwapThresholdChanged(0, DEFAULT_DUST_SWAP_THRESHOLD);
    }

    // -----------------------------------------------------------------------
    // Modifiers
    // -----------------------------------------------------------------------

    modifier onlyOwner() {
        if (msg.sender != _owner) revert NotOwner();
        _;
    }

    modifier whenPaused() {
        if (!isPaused()) revert RequiresPaused();
        _;
    }

    // -----------------------------------------------------------------------
    // Hook permissions
    // -----------------------------------------------------------------------

    /// @notice Declares required callback permissions for address flag mining.
    /// @return perms Hook permission flags expected from deployed hook address.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory perms) {
        perms.afterInitialize = true;
        perms.afterSwap = true;
        perms.afterSwapReturnDelta = true;
    }

    // -----------------------------------------------------------------------
    // Hook implementations
    // -----------------------------------------------------------------------

    function _afterInitialize(address, PoolKey calldata key, uint160, int24)
        internal
        override
        returns (bytes4)
    {
        _validateKey(key);

        (,, uint64 periodStart,,,,,,) = _unpackState(_state);
        if (periodStart != 0) revert AlreadyInitialized();

        uint64 nowTs = _now64();
        uint8 feeIdx = MODE_FLOOR;

        _state = _packState(0, 0, nowTs, feeIdx, isPaused(), 0, 0, 0, 0);

        poolManager.updateDynamicLPFee(key, _modeFee(feeIdx));
        emit FeeUpdated(_modeFee(feeIdx), feeIdx, 0, 0);

        return IHooks.afterInitialize.selector;
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        _validateKey(key);

        AfterSwapCtx memory ctx = _loadAfterSwapCtx();

        if (ctx.paused) {
            return (IHooks.afterSwap.selector, ctx.hookFeeDelta);
        }

        ctx.hookFeeDelta = _accrueHookFeeAfterSwap(key, params, delta, ctx.appliedFee);

        if (_handleIdleResetIfNeeded(key, delta, ctx)) {
            return (IHooks.afterSwap.selector, ctx.hookFeeDelta);
        }

        _closeElapsedPeriodsIfNeeded(ctx);

        _finalizeCurrentSwap(key, delta, ctx);

        return (IHooks.afterSwap.selector, ctx.hookFeeDelta);
    }

    /// @notice Loads unpacked controller state and computes per-call temporaries.
    /// @dev Pure context preparation with no state mutations.
    function _loadAfterSwapCtx() internal view returns (AfterSwapCtx memory ctx) {
        (
            ctx.periodVol,
            ctx.emaVolScaled,
            ctx.periodStart,
            ctx.feeIdx,
            ctx.paused,
            ctx.holdRemaining,
            ctx.upExtremeStreak,
            ctx.downStreak,
            ctx.emergencyStreak
        ) = _unpackState(_state);

        if (ctx.periodStart == 0) revert NotInitialized();

        ctx.appliedFee = _modeFee(ctx.feeIdx);
        ctx.nowTs = _now64();
        ctx.elapsed = ctx.nowTs - ctx.periodStart;
    }

    /// @notice Handles full state reset triggered by prolonged inactivity.
    /// @dev When the idle threshold is reached, resets to floor mode, writes `_state`,
    ///      updates the dynamic LP fee if the mode changed, and emits all relevant events.
    /// @return handled True if the idle reset was applied and `_afterSwap` should return early.
    function _handleIdleResetIfNeeded(
        PoolKey calldata key,
        BalanceDelta delta,
        AfterSwapCtx memory ctx
    ) internal returns (bool handled) {
        if (ctx.elapsed < _config.idleResetSeconds) return false;

        uint8 prevFeeIdx = ctx.feeIdx;
        uint64 closedPeriodStart = ctx.periodStart;
        uint96 emaBefore = ctx.emaVolScaled;
        uint16 stateBitsBefore = _packControllerTransitionCounters(
            ctx.paused, ctx.holdRemaining, ctx.upExtremeStreak, ctx.downStreak, ctx.emergencyStreak
        );

        ctx.emaVolScaled = 0;
        ctx.feeIdx = MODE_FLOOR;
        ctx.periodStart = ctx.nowTs;
        ctx.holdRemaining = 0;
        ctx.upExtremeStreak = 0;
        ctx.downStreak = 0;
        ctx.emergencyStreak = 0;

        _activatePendingDustSwapThreshold();
        ctx.periodVol = _addSwapVolumeUsd6(0, delta);

        _state = _packState(
            ctx.periodVol,
            ctx.emaVolScaled,
            ctx.periodStart,
            ctx.feeIdx,
            ctx.paused,
            ctx.holdRemaining,
            ctx.upExtremeStreak,
            ctx.downStreak,
            ctx.emergencyStreak
        );

        uint24 prevFee = _modeFee(prevFeeIdx);
        uint24 activeFee = _modeFee(ctx.feeIdx);
        if (ctx.feeIdx != prevFeeIdx) {
            poolManager.updateDynamicLPFee(key, activeFee);
            _emitFeeUpdate(activeFee, ctx.feeIdx, 0, 0);
        }

        _emitPeriodTrace(
            PeriodTrace({
                periodStart: closedPeriodStart,
                fromFee: prevFee,
                fromFeeIdx: prevFeeIdx,
                toFee: activeFee,
                toFeeIdx: ctx.feeIdx,
                periodVolume: 0,
                emaVolumeBefore: emaBefore,
                emaVolumeAfter: 0,
                approxLpFeesUsd: 0,
                decisionBits: 0,
                stateBitsBefore: stateBitsBefore,
                stateBitsAfter: _packControllerTransitionCounters(ctx.paused, ctx.holdRemaining, 0, 0, 0),
                reasonCode: REASON_IDLE_RESET
            })
        );
        emit IdleReset(activeFee, ctx.feeIdx);
        return true;
    }

    /// @notice Closes elapsed periods, runs the controller state machine, and emits period-close events.
    /// @dev Only modifies the in-memory context; does not write `_state`.
    function _closeElapsedPeriodsIfNeeded(AfterSwapCtx memory ctx) internal {
        if (ctx.elapsed < _config.periodSeconds) return;

        uint64 periods = ctx.elapsed / uint64(_config.periodSeconds);
        uint64 closeVol0 = ctx.periodVol;
        ctx.closeVolForEvent = closeVol0;
        uint64 periodStart0 = ctx.periodStart;

        uint8 prevFeeIdx = ctx.feeIdx;

        uint96 ema = ctx.emaVolScaled;
        uint8 f = ctx.feeIdx;
        uint8 hold = ctx.holdRemaining;
        uint8 upStreak = ctx.upExtremeStreak;
        uint8 down = ctx.downStreak;
        uint8 emergency = ctx.emergencyStreak;

        for (uint64 i = 0; i < periods; ++i) {
            uint64 closeVol = i == 0 ? closeVol0 : uint64(0);
            uint64 closedPeriodStart = periodStart0 + i * uint64(_config.periodSeconds);
            uint16 stateBitsBefore =
                _packControllerTransitionCounters(ctx.paused, hold, upStreak, down, emergency);

            uint8 fromFeeIdx = f;
            uint24 fromFee = _modeFee(fromFeeIdx);

            (uint96 emaAfter, uint96 emaBefore, ControllerTransitionResult memory transition) =
                _stepController(ema, f, closeVol, hold, upStreak, down, emergency);
            ema = emaAfter;
            f = transition.feeIdx;
            hold = transition.holdRemaining;
            upStreak = transition.upExtremeStreak;
            down = transition.downStreak;
            emergency = transition.emergencyStreak;

            _emitPeriodTrace(
                PeriodTrace({
                    periodStart: closedPeriodStart,
                    fromFee: fromFee,
                    fromFeeIdx: fromFeeIdx,
                    toFee: _modeFee(f),
                    toFeeIdx: f,
                    periodVolume: closeVol,
                    emaVolumeBefore: emaBefore,
                    emaVolumeAfter: ema,
                    approxLpFeesUsd: _estimateApproxLpFeesUsd6(closeVol, fromFee),
                    decisionBits: transition.decisionBits,
                    stateBitsBefore: stateBitsBefore,
                    stateBitsAfter: _packControllerTransitionCounters(
                        ctx.paused, hold, upStreak, down, emergency
                    ),
                    reasonCode: transition.reasonCode
                })
            );
        }

        ctx.emaVolScaled = ema;
        ctx.feeIdx = f;
        ctx.holdRemaining = hold;
        ctx.upExtremeStreak = upStreak;
        ctx.downStreak = down;
        ctx.emergencyStreak = emergency;
        ctx.feeChanged = ctx.feeIdx != prevFeeIdx;

        ctx.periodStart = ctx.periodStart + periods * uint64(_config.periodSeconds);

        ctx.periodVol = 0;
        _activatePendingDustSwapThreshold();
    }

    /// @notice Adds current swap volume, persists packed state, and syncs the dynamic LP fee.
    function _finalizeCurrentSwap(
        PoolKey calldata key,
        BalanceDelta delta,
        AfterSwapCtx memory ctx
    ) internal {
        ctx.periodVol = _addSwapVolumeUsd6(ctx.periodVol, delta);

        _state = _packState(
            ctx.periodVol,
            ctx.emaVolScaled,
            ctx.periodStart,
            ctx.feeIdx,
            ctx.paused,
            ctx.holdRemaining,
            ctx.upExtremeStreak,
            ctx.downStreak,
            ctx.emergencyStreak
        );

        if (ctx.feeChanged) {
            uint24 activeFee = _modeFee(ctx.feeIdx);
            poolManager.updateDynamicLPFee(key, activeFee);
            _emitFeeUpdate(activeFee, ctx.feeIdx, ctx.closeVolForEvent, ctx.emaVolScaled);
        }
    }

    // -----------------------------------------------------------------------
    // View functions
    // -----------------------------------------------------------------------

    /// @notice Returns whether controller is paused.
    /// @dev Paused mode freezes regulator transitions and suspends HookFee accrual; swaps remain active.
    function isPaused() public view returns (bool) {
        return ((_state >> PAUSED_BIT) & 1) == 1;
    }

    /// @notice Returns currently active LP fee tier.
    function currentFeeBips() external view returns (uint24) {
        (,, uint64 periodStart, uint8 feeIdx,,,,,) = _unpackState(_state);
        if (periodStart == 0) revert NotInitialized();
        return _modeFee(feeIdx);
    }

    /// @notice Returns packed runtime fields used by offchain telemetry.
    /// @return periodVolume Counted stable-side period volume in USD6.
    /// @return emaVolumeScaled Scaled EMA in USD6 * 1e6.
    /// @return periodStart Current period start timestamp.
    /// @return feeIdx Active mode id (`0` floor, `1` cash, `2` extreme).
    function unpackedState()
        external
        view
        returns (uint64 periodVolume, uint96 emaVolumeScaled, uint64 periodStart, uint8 feeIdx)
    {
        (periodVolume, emaVolumeScaled, periodStart, feeIdx,,,,,) = _unpackState(_state);
    }

    /// @notice Returns currently active mode id (`0` floor, `1` cash, `2` extreme).
    function currentMode() public view returns (uint8 mode) {
        (,, uint64 periodStart, uint8 feeIdx,,,,,) = _unpackState(_state);
        if (periodStart == 0) revert NotInitialized();
        mode = feeIdx;
    }

    /// @notice Returns floor LP fee.
    function floorFee() public view returns (uint24) {
        return _config.floorFee;
    }

    /// @notice Returns cash LP fee.
    function cashFee() public view returns (uint24) {
        return _config.cashFee;
    }

    /// @notice Returns extreme LP fee.
    function extremeFee() public view returns (uint24) {
        return _config.extremeFee;
    }

    /// @notice Returns minimum period volume required to consider entering cash mode.
    function enterCashMinVolume() public view returns (uint64) {
        return _config.enterCashMinVolume;
    }

    /// @notice Returns minimum current-period-to-EMA ratio, in percent, required to enter cash mode.
    function enterCashEmaRatioPct() public view returns (uint16) {
        return _config.enterCashEmaRatioPct;
    }

    /// @notice Returns number of periods to hold cash mode after entry.
    /// @dev Effective fully protected hold periods are `N - 1` because hold is decremented at period-close start.
    function holdCashPeriods() public view returns (uint8) {
        return _config.holdCashPeriods;
    }

    /// @notice Returns minimum period volume required to consider entering extreme mode.
    function enterExtremeMinVolume() public view returns (uint64) {
        return _config.enterExtremeMinVolume;
    }

    /// @notice Returns minimum current-period-to-EMA ratio, in percent, required to enter extreme mode.
    function enterExtremeEmaRatioPct() public view returns (uint16) {
        return _config.enterExtremeEmaRatioPct;
    }

    /// @notice Returns number of strong periods required to confirm entry into extreme mode.
    function enterExtremeConfirmPeriods() public view returns (uint8) {
        return _config.enterExtremeConfirmPeriods;
    }

    /// @notice Returns number of periods to hold extreme mode after entry.
    function holdExtremePeriods() public view returns (uint8) {
        return _config.holdExtremePeriods;
    }

    /// @notice Returns maximum current-period-to-EMA ratio, in percent, below which extreme mode may exit.
    function exitExtremeEmaRatioPct() public view returns (uint16) {
        return _config.exitExtremeEmaRatioPct;
    }

    /// @notice Returns number of weak periods required to confirm exit from extreme mode.
    function exitExtremeConfirmPeriods() public view returns (uint8) {
        return _config.exitExtremeConfirmPeriods;
    }

    /// @notice Returns maximum current-period-to-EMA ratio, in percent, below which cash mode may exit.
    function exitCashEmaRatioPct() public view returns (uint16) {
        return _config.exitCashEmaRatioPct;
    }

    /// @notice Returns number of weak periods required to confirm exit from cash mode.
    function exitCashConfirmPeriods() public view returns (uint8) {
        return _config.exitCashConfirmPeriods;
    }

    /// @notice Returns maximum period volume below which a low-volume reset candidate is counted.
    function lowVolumeReset() public view returns (uint64) {
        return _config.lowVolumeReset;
    }

    /// @notice Returns number of consecutive low-volume periods required to trigger the reset.
    function lowVolumeResetPeriods() public view returns (uint8) {
        return _config.lowVolumeResetPeriods;
    }

    /// @notice Returns period duration in seconds.
    function periodSeconds() public view returns (uint32) {
        return _config.periodSeconds;
    }

    /// @notice Returns EMA denominator.
    function emaPeriods() public view returns (uint8) {
        return _config.emaPeriods;
    }

    /// @notice Returns inactivity duration after which the hook performs the idle reset path.
    /// @dev This value is always strictly greater than `periodSeconds`.
    function idleResetSeconds() public view returns (uint32) {
        return _config.idleResetSeconds;
    }

    /// @notice Returns current owner address.
    function owner() public view returns (address) {
        return _owner;
    }

    /// @notice Returns pending owner address.
    function pendingOwner() public view returns (address) {
        return _pendingOwner;
    }

    /// @notice Returns current hook fee percent used by the hook settlement formula.
    function hookFeePercent() public view returns (uint16) {
        return _config.hookFeePercent;
    }

    /// @notice Returns minimum swap size below which a swap is treated as dust and ignored for meaningful flow accounting.
    function dustSwapThreshold() public view returns (uint64) {
        return _config.dustSwapThreshold;
    }

    /// @notice Returns pending HookFee percent timelock data.
    function pendingHookFeePercentChange()
        external
        view
        returns (bool exists, uint16 nextValue, uint64 executeAfter)
    {
        return (_hasPendingHookFeePercentChange, _pendingHookFeePercent, _pendingHookFeePercentExecuteAfter);
    }

    /// @notice Returns pending dust-swap threshold update.
    /// @dev This update path is intentionally timelock-free and activates on next period boundary only.
    function pendingDustSwapThresholdChange() external view returns (bool exists, uint64 nextValue) {
        return (_hasPendingDustSwapThresholdChange, _pendingDustSwapThreshold);
    }

    /// @notice Returns grouped controller transition params.
    function getControllerSettings() external view returns (ControllerSettings memory p) {
        p = ControllerSettings({
            enterCashMinVolume: _config.enterCashMinVolume,
            enterCashEmaRatioPct: _config.enterCashEmaRatioPct,
            holdCashPeriods: _config.holdCashPeriods,
            enterExtremeMinVolume: _config.enterExtremeMinVolume,
            enterExtremeEmaRatioPct: _config.enterExtremeEmaRatioPct,
            enterExtremeConfirmPeriods: _config.enterExtremeConfirmPeriods,
            holdExtremePeriods: _config.holdExtremePeriods,
            exitExtremeEmaRatioPct: _config.exitExtremeEmaRatioPct,
            exitExtremeConfirmPeriods: _config.exitExtremeConfirmPeriods,
            exitCashEmaRatioPct: _config.exitCashEmaRatioPct,
            exitCashConfirmPeriods: _config.exitCashConfirmPeriods
        });
    }

    /// @notice Returns reset and protective-logic parameters.
    function getResetSettings()
        external
        view
        returns (uint32 idleResetSeconds_, uint64 lowVolumeReset_, uint8 lowVolumeResetPeriods_)
    {
        idleResetSeconds_ = _config.idleResetSeconds;
        lowVolumeReset_ = _config.lowVolumeReset;
        lowVolumeResetPeriods_ = _config.lowVolumeResetPeriods;
    }

    /// @notice Returns explicit mode fees.
    function getModeFees() external view returns (uint24 floorFee_, uint24 cashFee_, uint24 extremeFee_) {
        floorFee_ = _config.floorFee;
        cashFee_ = _config.cashFee;
        extremeFee_ = _config.extremeFee;
    }

    /// @notice Returns detailed packed state counters for debugging and monitoring.
    /// @dev `downStreak` is context-dependent and must be interpreted together with current `feeIdx`:
    /// when `feeIdx==MODE_CASH` it tracks cash->floor confirmations, and when `feeIdx==MODE_EXTREME` it tracks
    /// extreme->cash confirmations.
    function getStateDebug()
        external
        view
        returns (
            uint8 feeIdx,
            uint8 holdRemaining,
            uint8 upExtremeStreak,
            uint8 downStreak,
            uint8 emergencyStreak,
            uint64 periodStart,
            uint64 periodVol,
            uint96 emaVolScaled,
            bool paused
        )
    {
        (
            periodVol,
            emaVolScaled,
            periodStart,
            feeIdx,
            paused,
            holdRemaining,
            upExtremeStreak,
            downStreak,
            emergencyStreak
        ) = _unpackState(_state);
    }

    /// @notice Returns accrued HookFee balances by pool currency order.
    function hookFeesAccrued() external view returns (uint256 token0, uint256 token1) {
        return (_hookFees0, _hookFees1);
    }

    // -----------------------------------------------------------------------
    // Admin and owner controls
    // -----------------------------------------------------------------------

    /// @notice Proposes a new owner address. Acceptance must be performed by pending owner.
    /// @dev Rejects zero address and current owner to avoid self-pending-owner traps.
    function proposeNewOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0) || newOwner == _owner) revert InvalidOwner();
        if (_pendingOwner != address(0)) revert PendingOwnerExists();
        _pendingOwner = newOwner;
        emit OwnerTransferStarted(_owner, newOwner);
    }

    /// @notice Cancels currently pending owner transfer.
    function cancelOwnerTransfer() external onlyOwner {
        address pending = _pendingOwner;
        if (pending == address(0)) revert NoPendingOwnerTransfer();
        _pendingOwner = address(0);
        emit OwnerTransferCancelled(pending);
    }

    /// @notice Accepts owner role by pending owner.
    function acceptOwner() external {
        address pending = _pendingOwner;
        if (msg.sender != pending) revert NotPendingOwner();

        address oldOwner = _owner;
        _pendingOwner = address(0);
        _owner = pending;

        emit OwnerTransferAccepted(oldOwner, pending);
        emit OwnerUpdated(oldOwner, pending);
    }

    /// @notice Schedules HookFee percent change through 48h timelock.
    function scheduleHookFeePercentChange(uint16 newHookFeePercent) external onlyOwner {
        if (_hasPendingHookFeePercentChange) revert PendingHookFeePercentChangeExists();
        _validateHookFeePercent(newHookFeePercent);

        uint64 executeAfter = _now64() + HOOK_FEE_PERCENT_CHANGE_DELAY;
        _hasPendingHookFeePercentChange = true;
        _pendingHookFeePercent = newHookFeePercent;
        _pendingHookFeePercentExecuteAfter = executeAfter;

        emit HookFeeChangeScheduled(newHookFeePercent, executeAfter);
    }

    /// @notice Cancels scheduled HookFee percent change.
    function cancelHookFeePercentChange() external onlyOwner {
        if (!_hasPendingHookFeePercentChange) revert NoPendingHookFeePercentChange();

        uint16 cancelled = _pendingHookFeePercent;
        _hasPendingHookFeePercentChange = false;
        _pendingHookFeePercent = 0;
        _pendingHookFeePercentExecuteAfter = 0;

        emit HookFeeChangeCancelled(cancelled);
    }

    /// @notice Executes scheduled HookFee percent change after timelock delay.
    function executeHookFeePercentChange() external onlyOwner {
        if (!_hasPendingHookFeePercentChange) revert NoPendingHookFeePercentChange();

        uint64 executeAfter = _pendingHookFeePercentExecuteAfter;
        if (_now64() < executeAfter) revert HookFeePercentChangeNotReady(executeAfter);

        uint16 oldValue = _config.hookFeePercent;
        uint16 newValue = _pendingHookFeePercent;

        _hasPendingHookFeePercentChange = false;
        _pendingHookFeePercent = 0;
        _pendingHookFeePercentExecuteAfter = 0;

        _setHookFeePercentInternal(newValue);
        emit HookFeeChanged(oldValue, newValue);
    }

    /// @notice Schedules a new dust-swap threshold.
    /// @dev Allowed range is `[1e6, 10e6]` in USD6 units.
    /// @dev New value is applied only at the next period boundary in `afterSwap`.
    /// @dev This path intentionally has no timelock; operations should use offchain recalibration discipline.
    function scheduleDustSwapThresholdChange(uint64 newDustSwapThreshold_) external onlyOwner {
        if (_hasPendingDustSwapThresholdChange) revert PendingDustSwapThresholdChangeExists();
        _validateDustSwapThreshold(newDustSwapThreshold_);

        _hasPendingDustSwapThresholdChange = true;
        _pendingDustSwapThreshold = newDustSwapThreshold_;

        emit DustSwapThresholdChangeScheduled(newDustSwapThreshold_);
    }

    /// @notice Cancels scheduled dust-swap threshold change.
    function cancelDustSwapThresholdChange() external onlyOwner {
        if (!_hasPendingDustSwapThresholdChange) revert NoPendingDustSwapThresholdChange();

        uint64 cancelled = _pendingDustSwapThreshold;
        _hasPendingDustSwapThresholdChange = false;
        _pendingDustSwapThreshold = 0;

        emit DustSwapThresholdChangeCancelled(cancelled);
    }

    /// @notice Updates explicit mode fees while paused.
    /// @dev Preserves EMA, always clears hold/streak counters, and starts a fresh open period.
    /// @dev Active mode id is preserved; if the active mode fee changes, LP fee is updated immediately.
    function setModeFees(uint24 floorFee_, uint24 cashFee_, uint24 extremeFee_)
        external
        onlyOwner
        whenPaused
    {
        (, uint96 emaVolScaled, uint64 periodStart, uint8 feeIdx, bool paused_,,,,) = _unpackState(_state);
        uint24 prevActiveFee = _modeFee(feeIdx);

        _setModeFeesInternal(floorFee_, cashFee_, extremeFee_);
        emit ModeFeesUpdated(floorFee_, cashFee_, extremeFee_);

        if (periodStart == 0) return;

        uint64 nextPeriodStart = _now64();
        _state = _packState(0, emaVolScaled, nextPeriodStart, feeIdx, paused_, 0, 0, 0, 0);

        uint24 activeFee = _modeFee(feeIdx);
        if (activeFee != prevActiveFee) {
            poolManager.updateDynamicLPFee(_poolKey(), activeFee);
            emit FeeUpdated(activeFee, feeIdx, 0, emaVolScaled);
        }
    }

    /// @notice Updates controller transition parameters. Takes effect immediately without resetting EMA or counters.
    /// @dev Hold counters are decremented at the start of each closed period. Hold blocks only the ordinary downward
    /// path, the emergency path still accumulates, configured hold `N` yields `N - 1` fully protected periods, the
    /// earliest ordinary cash->floor close under uninterrupted weakness is
    /// `holdCashPeriods + exitCashConfirmPeriods - 1`, the earliest ordinary extreme->cash close is
    /// `holdExtremePeriods + exitExtremeConfirmPeriods - 1`.
    /// @dev Reset-group parameters (`idleResetSeconds`, `lowVolumeReset`, `lowVolumeResetPeriods`) are managed
    /// separately via `setResetSettings`.
    function setControllerSettings(ControllerSettings calldata p) external onlyOwner {
        _setControllerSettingsInternal(p);
        emit ControllerSettingsUpdated(
            p.enterCashMinVolume,
            p.enterCashEmaRatioPct,
            p.holdCashPeriods,
            p.enterExtremeMinVolume,
            p.enterExtremeEmaRatioPct,
            p.enterExtremeConfirmPeriods,
            p.holdExtremePeriods,
            p.exitExtremeEmaRatioPct,
            p.exitExtremeConfirmPeriods,
            p.exitCashEmaRatioPct,
            p.exitCashConfirmPeriods
        );
    }

    /// @notice Updates model parameters (`periodSeconds`, `emaPeriods`) while paused.
    /// @dev Treated as a model change: performs a hard safe reset — floor mode, zero EMA/counters,
    /// fresh open period, and immediate LP fee sync when the active tier changes.
    /// @dev Requires the hook to be paused; equality of `periodSeconds` and `emaPeriods` with current
    /// values is allowed (results in a fresh period without mode change).
    function setModel(uint32 periodSeconds_, uint8 emaPeriods_) external onlyOwner whenPaused {
        (
            ,
            uint96 emaVolScaled,
            uint64 periodStart,
            uint8 feeIdx,
            bool paused_,
            ,
            ,
            ,

        ) = _unpackState(_state);

        uint24 prevActiveFee = _modeFee(feeIdx);

        _setModelInternal(periodSeconds_, emaPeriods_);
        emit ModelUpdated(periodSeconds_, emaPeriods_);

        if (periodStart == 0) return;

        feeIdx = MODE_FLOOR;
        emaVolScaled = 0;

        _state = _packState(0, emaVolScaled, _now64(), feeIdx, paused_, 0, 0, 0, 0);

        uint24 activeFee = _modeFee(feeIdx);
        if (activeFee != prevActiveFee) {
            poolManager.updateDynamicLPFee(_poolKey(), activeFee);
            emit FeeUpdated(activeFee, feeIdx, 0, 0);
        }
    }

    /// @notice Updates reset and protective-logic parameters. Takes effect immediately without resetting state.
    /// @dev `idleResetSeconds_` must be strictly greater than the current `periodSeconds`.
    /// @dev `lowVolumeReset_` must be nonzero and strictly less than `enterCashMinVolume`.
    /// @dev `lowVolumeResetPeriods_` must be nonzero.
    function setResetSettings(uint32 idleResetSeconds_, uint64 lowVolumeReset_, uint8 lowVolumeResetPeriods_)
        external
        onlyOwner
    {
        _setResetSettingsInternal(idleResetSeconds_, lowVolumeReset_, lowVolumeResetPeriods_);
        emit ResetSettingsUpdated(idleResetSeconds_, lowVolumeReset_, lowVolumeResetPeriods_);
    }

    /// @notice Enters paused freeze mode.
    /// @dev Keeps feeIdx, EMA and streak counters unchanged. Clears only open-period volume and restarts period clock.
    /// @dev Freezes regulator transitions at the last active LP fee tier.
    /// @dev Does not disable swaps; only new HookFee accrual is suspended while paused.
    function pause() external onlyOwner {
        if (isPaused()) return;

        (
            ,
            uint96 emaVolScaled,
            uint64 periodStart,
            uint8 feeIdx,,
            uint8 holdRemaining,
            uint8 upExtremeStreak,
            uint8 downStreak,
            uint8 emergencyStreak
        ) = _unpackState(_state);

        uint64 nextPeriodStart = periodStart == 0 ? uint64(0) : _now64();
        _state = _packState(
            0,
            emaVolScaled,
            nextPeriodStart,
            feeIdx,
            true,
            holdRemaining,
            upExtremeStreak,
            downStreak,
            emergencyStreak
        );

        emit Paused(_modeFee(feeIdx), feeIdx);
    }

    /// @notice Exits paused freeze mode.
    /// @dev Continues from the same fee mode and counters, with a fresh open period.
    /// @dev LP fee tier stays at the frozen value until normal transitions run after unpause.
    /// @dev Resuming does not retroactively accrue HookFee for swaps that executed while paused.
    function unpause() external onlyOwner {
        if (!isPaused()) return;

        (
            ,
            uint96 emaVolScaled,
            uint64 periodStart,
            uint8 feeIdx,,
            uint8 holdRemaining,
            uint8 upExtremeStreak,
            uint8 downStreak,
            uint8 emergencyStreak
        ) = _unpackState(_state);

        uint64 nextPeriodStart = periodStart == 0 ? uint64(0) : _now64();
        _state = _packState(
            0,
            emaVolScaled,
            nextPeriodStart,
            feeIdx,
            false,
            holdRemaining,
            upExtremeStreak,
            downStreak,
            emergencyStreak
        );

        emit Unpaused(_modeFee(feeIdx), feeIdx);
    }

    /// @notice Emergency reset while paused to floor mode.
    /// @dev Clears EMA/counters (`emaVolumeScaled`, hold/streak counters) and restarts open period state.
    /// @dev If the target fee index already matches current index, fee state still resets but no `FeeUpdated` is emitted.
    function emergencyResetToFloor() external onlyOwner whenPaused {
        _emergencyReset(MODE_FLOOR, true);
    }

    /// @notice Emergency reset while paused to cash mode.
    /// @dev Clears EMA/counters (`emaVolumeScaled`, hold/streak counters) and restarts open period state.
    /// @dev If the target fee index already matches current index, fee state still resets but no `FeeUpdated` is emitted.
    function emergencyResetToCash() external onlyOwner whenPaused {
        _emergencyReset(MODE_CASH, false);
    }

    /// @notice Claims selected amounts of accrued HookFees.
    /// @dev `to` must equal current `owner()`.
    /// @dev Uses PoolManager accounting withdrawal flow (`unlock` -> `burn` -> `take`) to transfer funds to recipient.
    function claimHookFees(address to, uint256 amount0, uint256 amount1) external onlyOwner {
        _claimHookFeesInternal(to, amount0, amount1);
    }

    /// @notice Claims all accrued HookFees to current `owner()`.
    /// @dev Uses PoolManager accounting withdrawal flow (`unlock` -> `burn` -> `take`) to transfer funds to recipient.
    function claimAllHookFees() external onlyOwner {
        _claimHookFeesInternal(_owner, _hookFees0, _hookFees1);
    }

    /// @inheritdoc IUnlockCallback
    /// @dev Restricted to PoolManager and used only for HookFee claim settlement.
    function unlockCallback(bytes calldata data) external override onlyPoolManager returns (bytes memory) {
        HookFeeClaimUnlockData memory claimData = abi.decode(data, (HookFeeClaimUnlockData));
        if (claimData.recipient == address(0)) revert InvalidUnlockData();
        _withdrawHookFeeViaPoolManagerAccounting(claimData.recipient, claimData.amount0, claimData.amount1);
        return "";
    }

    /// @notice Rescues non-pool ERC20 balance from the hook contract.
    function rescueToken(Currency currency, uint256 amount) external onlyOwner {
        if (currency == poolCurrency0 || currency == poolCurrency1) revert InvalidRescueCurrency();

        currency.transfer(_owner, amount);
        emit RescueTransfer(Currency.unwrap(currency), amount, _owner);
    }

    /// @notice Rescues ETH balance from the hook contract to owner.
    function rescueETH(uint256 amount) external onlyOwner {
        if (amount > address(this).balance) revert ClaimTooLarge();

        (bool ok,) = payable(_owner).call{value: amount}("");
        if (!ok) revert EthTransferFailed();

        emit RescueTransfer(address(0), amount, _owner);
    }

    /// @notice Rejects direct ETH transfers.
    receive() external payable {
        revert EthReceiveRejected();
    }

    // -----------------------------------------------------------------------
    // Internal configuration helpers
    // -----------------------------------------------------------------------

    function _setOwnerInternal(address newOwner) internal {
        if (newOwner == address(0)) revert InvalidOwner();
        _owner = newOwner;
    }

    function _validateHookFeePercent(uint16 newHookFeePercent) internal pure {
        if (newHookFeePercent > MAX_HOOK_FEE_PERCENT) {
            revert HookFeePercentLimitExceeded(newHookFeePercent, MAX_HOOK_FEE_PERCENT);
        }
    }

    function _setHookFeePercentInternal(uint16 newHookFeePercent) internal {
        _validateHookFeePercent(newHookFeePercent);
        _config.hookFeePercent = newHookFeePercent;
    }

    /// @notice Validates dust-swap threshold bounds.
    /// @dev Allowed range is `[1e6, 10e6]` in USD6 units.
    function _validateDustSwapThreshold(uint64 newDustSwapThreshold_) internal pure {
        if (
            newDustSwapThreshold_ < MIN_DUST_SWAP_THRESHOLD
                || newDustSwapThreshold_ > MAX_DUST_SWAP_THRESHOLD
        ) {
            revert InvalidDustSwapThreshold();
        }
    }

    function _setModelInternal(uint32 periodSeconds_, uint8 emaPeriods_) internal {
        if (periodSeconds_ == 0) revert InvalidConfig();
        if (emaPeriods_ < 2 || emaPeriods_ > MAX_EMA_PERIODS) revert InvalidConfig();

        _config.periodSeconds = periodSeconds_;
        _config.emaPeriods = emaPeriods_;
    }

    function _setResetSettingsInternal(
        uint32 idleResetSeconds_,
        uint64 lowVolumeReset_,
        uint8 lowVolumeResetPeriods_
    ) internal {
        if (idleResetSeconds_ <= _config.periodSeconds) revert InvalidConfig();
        if (uint256(idleResetSeconds_) > uint256(_config.periodSeconds) * MAX_LULL_PERIODS) revert InvalidConfig();
        // lowVolumeReset_ at zero would force permanent trigger semantics.
        if (lowVolumeReset_ == 0) revert InvalidConfig();
        if (lowVolumeReset_ >= _config.enterCashMinVolume) revert InvalidConfig();
        if (lowVolumeResetPeriods_ == 0 || lowVolumeResetPeriods_ > MAX_EMERGENCY_STREAK) {
            revert InvalidConfirmPeriods();
        }

        _config.idleResetSeconds = idleResetSeconds_;
        _config.lowVolumeReset = lowVolumeReset_;
        _config.lowVolumeResetPeriods = lowVolumeResetPeriods_;
    }

    function _setControllerSettingsInternal(ControllerSettings memory p) internal {
        if (p.holdCashPeriods == 0 || p.holdCashPeriods > MAX_HOLD_PERIODS) revert InvalidHoldPeriods();
        if (p.holdExtremePeriods == 0 || p.holdExtremePeriods > MAX_HOLD_PERIODS) {
            revert InvalidHoldPeriods();
        }

        if (p.enterExtremeConfirmPeriods == 0 || p.enterExtremeConfirmPeriods > MAX_UP_EXTREME_STREAK) {
            revert InvalidConfirmPeriods();
        }
        if (p.exitExtremeConfirmPeriods == 0 || p.exitExtremeConfirmPeriods > MAX_DOWN_STREAK) {
            revert InvalidConfirmPeriods();
        }
        if (p.exitCashConfirmPeriods == 0 || p.exitCashConfirmPeriods > MAX_DOWN_STREAK) {
            revert InvalidConfirmPeriods();
        }
        // Cross-parameter consistency guards.
        if (p.enterCashMinVolume > p.enterExtremeMinVolume) revert InvalidConfig();
        if (p.enterCashEmaRatioPct > p.enterExtremeEmaRatioPct) revert InvalidConfig();
        if (p.exitCashEmaRatioPct < p.exitExtremeEmaRatioPct) revert InvalidConfig();
        // Cross-group guard: stored lowVolumeReset must remain strictly below enterCashMinVolume.
        if (_config.lowVolumeReset > 0 && p.enterCashMinVolume <= _config.lowVolumeReset) revert InvalidConfig();

        _config.enterCashMinVolume = p.enterCashMinVolume;
        _config.enterCashEmaRatioPct = p.enterCashEmaRatioPct;
        _config.holdCashPeriods = p.holdCashPeriods;
        _config.enterExtremeMinVolume = p.enterExtremeMinVolume;
        _config.enterExtremeEmaRatioPct = p.enterExtremeEmaRatioPct;
        _config.enterExtremeConfirmPeriods = p.enterExtremeConfirmPeriods;
        _config.holdExtremePeriods = p.holdExtremePeriods;
        _config.exitExtremeEmaRatioPct = p.exitExtremeEmaRatioPct;
        _config.exitExtremeConfirmPeriods = p.exitExtremeConfirmPeriods;
        _config.exitCashEmaRatioPct = p.exitCashEmaRatioPct;
        _config.exitCashConfirmPeriods = p.exitCashConfirmPeriods;
    }

    function _setModeFeesInternal(uint24 floorFee_, uint24 cashFee_, uint24 extremeFee_) internal {
        if (
            floorFee_ == 0 || floorFee_ >= cashFee_ || cashFee_ >= extremeFee_
                || extremeFee_ > LPFeeLibrary.MAX_LP_FEE
        ) {
            revert InvalidConfig();
        }
        _config.floorFee = floorFee_;
        _config.cashFee = cashFee_;
        _config.extremeFee = extremeFee_;
    }

    function _emergencyReset(uint8 targetFeeIdx, bool toFloor) internal {
        (,, uint64 periodStart, uint8 prevFeeIdx, bool paused_,,,,) = _unpackState(_state);

        if (periodStart == 0) revert NotInitialized();

        uint64 nowTs = _now64();
        _state = _packState(0, 0, nowTs, targetFeeIdx, paused_, 0, 0, 0, 0);

        if (prevFeeIdx != targetFeeIdx) {
            uint24 targetFee = _modeFee(targetFeeIdx);
            poolManager.updateDynamicLPFee(_poolKey(), targetFee);
            emit FeeUpdated(targetFee, targetFeeIdx, 0, 0);
        }

        if (toFloor) {
            emit EmergencyResetToFloorApplied(targetFeeIdx, nowTs, 0);
        } else {
            emit EmergencyResetToCashApplied(targetFeeIdx, nowTs, 0);
        }
    }

    /// @notice Activates pending telemetry threshold update.
    /// @dev Called only on period rollover so threshold never changes mid-period.
    function _activatePendingDustSwapThreshold() internal {
        if (!_hasPendingDustSwapThresholdChange) return;

        uint64 oldValue = _config.dustSwapThreshold;
        uint64 newValue = _pendingDustSwapThreshold;

        _hasPendingDustSwapThresholdChange = false;
        _pendingDustSwapThreshold = 0;

        _config.dustSwapThreshold = newValue;
        emit DustSwapThresholdChanged(oldValue, newValue);
    }

    /// @notice Executes HookFee claim through PoolManager unlock callback flow.
    /// @dev Internal accounting is reduced before unlock; whole operation reverts atomically on failure.
    function _claimHookFeesInternal(address to, uint256 amount0, uint256 amount1) internal {
        if (to != _owner) revert InvalidRecipient();
        if (amount0 > _hookFees0 || amount1 > _hookFees1) revert ClaimTooLarge();
        if (amount0 == 0 && amount1 == 0) return;

        _hookFees0 -= amount0;
        _hookFees1 -= amount1;

        poolManager.unlock(
            abi.encode(HookFeeClaimUnlockData({recipient: to, amount0: amount0, amount1: amount1}))
        );
        emit HookFeesClaimed(to, amount0, amount1);
    }

    /// @notice Converts hook ERC6909 claims into ERC20/native payouts and sends funds to recipient.
    /// @dev Burn creates positive PoolManager delta for this hook; take withdraws the same amount to `to`.
    function _withdrawHookFeeViaPoolManagerAccounting(address to, uint256 amount0, uint256 amount1) internal {
        if (amount0 > 0) {
            _withdrawCurrencyClaim(poolCurrency0, to, amount0);
        }
        if (amount1 > 0) {
            _withdrawCurrencyClaim(poolCurrency1, to, amount1);
        }
    }

    function _withdrawCurrencyClaim(Currency currency, address to, uint256 amount) internal {
        while (amount > 0) {
            uint256 chunk =
                amount > MAX_POOLMANAGER_SETTLEMENT_AMOUNT ? MAX_POOLMANAGER_SETTLEMENT_AMOUNT : amount;
            poolManager.burn(address(this), currency.toId(), chunk);
            poolManager.take(currency, to, chunk);
            unchecked {
                amount -= chunk;
            }
        }
    }

    // -----------------------------------------------------------------------
    // Internal hook helpers
    // -----------------------------------------------------------------------

    function _poolKey() internal view returns (PoolKey memory key) {
        key = PoolKey({
            currency0: poolCurrency0,
            currency1: poolCurrency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: poolTickSpacing,
            hooks: IHooks(address(this))
        });
    }

    function _validateKey(PoolKey calldata key) internal view {
        if (
            !(key.currency0 == poolCurrency0) || !(key.currency1 == poolCurrency1)
                || key.tickSpacing != poolTickSpacing
        ) {
            revert InvalidPoolKey();
        }
        // Require exact dynamic-fee marker for the bound pool key.
        if (key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG) revert NotDynamicFeePool();
        if (address(key.hooks) != address(this)) revert InvalidPoolKey();
    }

    function _now64() internal view returns (uint64) {
        return uint64(block.timestamp);
    }

    function _modeFee(uint8 idx) internal view returns (uint24) {
        if (idx == MODE_FLOOR) return _config.floorFee;
        if (idx == MODE_CASH) return _config.cashFee;
        if (idx == MODE_EXTREME) return _config.extremeFee;
        revert InvalidConfig();
    }

    /// @notice Accrues per-swap hook fee from swap settlement data using the active fee tier.
    /// @dev Estimation uses the unspecified side selected by the current exact-input/exact-output execution path.
    /// @dev Small systematic deviations between exact-input and exact-output paths are expected by design.
    /// @dev Hook fee is derived from swap settlement data and the active fee tier.
    /// @dev The configured hookFeePercent is a hook-specific calculation parameter and should not be interpreted as a literal share of separately observed LP fees.
    function _accrueHookFeeAfterSwap(
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        uint24 appliedFeeBips
    ) internal returns (int128 hookFeeDelta) {
        uint16 hookFeePct = _config.hookFeePercent;
        if (hookFeePct == 0) return 0;

        (Currency unspecifiedCurrency, uint256 absUnspecified) = _hookFeeBase(key, params, delta);
        if (absUnspecified == 0) return 0;

        uint256 amount = _hookFeeAmount(absUnspecified, appliedFeeBips, hookFeePct);
        if (amount == 0) return 0;

        _creditHookFee(unspecifiedCurrency, amount);
        return int128(uint128(amount));
    }

    /// @notice Determines the unspecified currency and its absolute amount for hook fee calculation.
    /// @dev Selects the unspecified side based on the swap execution path (exact-input vs exact-output).
    function _hookFeeBase(
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta
    ) internal pure returns (Currency unspecifiedCurrency, uint256 absUnspecified) {
        bool specifiedTokenIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        unspecifiedCurrency = specifiedTokenIs0 ? key.currency1 : key.currency0;
        int128 unspecifiedAmountSigned = specifiedTokenIs0 ? delta.amount1() : delta.amount0();
        absUnspecified = unspecifiedAmountSigned < 0
            ? uint256(-int256(unspecifiedAmountSigned))
            : uint256(uint128(unspecifiedAmountSigned));
    }

    /// @notice Computes hook fee from the unspecified-side base and active fee tier.
    /// @dev Formula: `(absUnspecified * appliedFeeBips / FEE_SCALE) * hookFeePct / 100`.
    function _hookFeeAmount(
        uint256 absUnspecified,
        uint24 appliedFeeBips,
        uint16 hookFeePct
    ) internal pure returns (uint256 hookFeeAmount) {
        uint256 lpFeeAmount = (absUnspecified * uint256(appliedFeeBips)) / FEE_SCALE;
        hookFeeAmount = (lpFeeAmount * uint256(hookFeePct)) / 100;
        if (hookFeeAmount > uint256(uint128(type(int128).max))) {
            hookFeeAmount = uint256(uint128(type(int128).max));
        }
    }

    /// @notice Records hook fee in internal accounting and mints ERC6909 claim in PoolManager.
    function _creditHookFee(Currency unspecifiedCurrency, uint256 hookFeeAmount) internal {
        if (unspecifiedCurrency == poolCurrency0) {
            _hookFees0 += hookFeeAmount;
        } else {
            _hookFees1 += hookFeeAmount;
        }
        // Persist claimable balance in PoolManager ERC6909 accounting during the same unlocked swap context.
        poolManager.mint(address(this), unspecifiedCurrency.toId(), hookFeeAmount);
    }

    function _addSwapVolumeUsd6(uint64 current, BalanceDelta delta) internal view returns (uint64) {
        int128 stableAmount = _stableIsCurrency0 ? delta.amount0() : delta.amount1();
        uint256 absStable = stableAmount < 0 ? uint256(-int256(stableAmount)) : uint256(uint128(stableAmount));

        uint256 usd6 = _toUsd6(absStable);
        if (usd6 < _config.dustSwapThreshold) {
            return current;
        }

        uint256 sum = uint256(current) + usd6;
        if (sum > type(uint64).max) return type(uint64).max;
        return uint64(sum);
    }

    function _toUsd6(uint256 stableAmount) internal view returns (uint256) {
        if (_stableScale == 1) return stableAmount;
        return stableAmount / _stableScale;
    }

    function _updateEmaScaled(uint96 emaScaled, uint64 closeVol) internal view returns (uint96) {
        if (emaScaled == 0) {
            if (closeVol == 0) return 0;
            uint256 seeded = uint256(closeVol) * EMA_SCALE;
            if (seeded > type(uint96).max) return type(uint96).max;
            return uint96(seeded);
        }

        uint256 n = uint256(_config.emaPeriods);
        uint256 updated = (uint256(emaScaled) * (n - 1) + uint256(closeVol) * EMA_SCALE) / n;
        if (updated > type(uint96).max) return type(uint96).max;
        return uint96(updated);
    }

    function _estimateApproxLpFeesUsd6(uint64 closeVol, uint24 feeBips) internal pure returns (uint64) {
        uint256 fees = (uint256(closeVol) * uint256(feeBips)) / FEE_SCALE;
        if (fees > type(uint64).max) return type(uint64).max;
        return uint64(fees);
    }

    /// @notice Emits both `PeriodClosed` and `ControllerTransitionTrace` for a closed period.
    function _emitPeriodTrace(PeriodTrace memory trace) internal {
        emit PeriodClosed(
            trace.fromFee,
            trace.fromFeeIdx,
            trace.toFee,
            trace.toFeeIdx,
            trace.periodVolume,
            trace.emaVolumeAfter,
            trace.approxLpFeesUsd,
            trace.reasonCode
        );
        _emitControllerTransitionTrace(trace);
    }

    /// @notice Emits `FeeUpdated` event.
    function _emitFeeUpdate(uint24 fee, uint8 feeIdx, uint64 periodVolume, uint96 emaVolumeScaled) internal {
        emit FeeUpdated(fee, feeIdx, periodVolume, emaVolumeScaled);
    }

    function _emitControllerTransitionTrace(PeriodTrace memory trace) internal {
        emit ControllerTransitionTrace(
            trace.periodStart,
            trace.fromFee,
            trace.fromFeeIdx,
            trace.toFee,
            trace.toFeeIdx,
            trace.periodVolume,
            trace.emaVolumeBefore,
            trace.emaVolumeAfter,
            trace.approxLpFeesUsd,
            trace.decisionBits,
            trace.stateBitsBefore,
            trace.stateBitsAfter,
            trace.reasonCode
        );
    }

    function _packControllerTransitionCounters(
        bool paused,
        uint8 holdRemaining,
        uint8 upExtremeStreak,
        uint8 downStreak,
        uint8 emergencyStreak
    ) internal pure returns (uint16 counters) {
        if (paused) counters |= 1;
        counters |= uint16(holdRemaining) << TRACE_COUNTER_HOLD_SHIFT;
        counters |= uint16(upExtremeStreak) << TRACE_COUNTER_UP_EXTREME_SHIFT;
        counters |= uint16(downStreak) << TRACE_COUNTER_DOWN_SHIFT;
        counters |= uint16(emergencyStreak) << TRACE_COUNTER_EMERGENCY_SHIFT;
    }

    function _incrementStreak(uint8 current, uint8 maxValue) internal pure returns (uint8) {
        return current < maxValue ? current + 1 : maxValue;
    }

    /// @notice Runs one controller step: updates EMA and computes mode transition.
    /// @dev No state mutations; returns updated EMA and transition result.
    function _stepController(
        uint96 ema,
        uint8 feeIdx,
        uint64 closeVol,
        uint8 holdRemaining,
        uint8 upExtremeStreak,
        uint8 downStreak,
        uint8 emergencyStreak
    )
        internal
        view
        returns (uint96 emaAfter, uint96 emaBefore, ControllerTransitionResult memory transition)
    {
        emaBefore = ema;
        emaAfter = _updateEmaScaled(ema, closeVol);
        bool bootstrapV2 = emaBefore == 0 && closeVol > 0;
        transition = _computeNextModeV2(
            feeIdx, closeVol, emaAfter, bootstrapV2, holdRemaining, upExtremeStreak, downStreak, emergencyStreak
        );
    }

    /// @notice Computes the next LP-fee mode and transition counters for a closed period.
    /// @dev Hold is decremented at period-close start, so configured hold `N` yields `N - 1` fully protected periods.
    /// @dev Hold blocks only the ordinary downward path, while the automatic emergency floor trigger is evaluated
    /// before hold protection and can reset to `FLOOR` even when `holdRemaining > 0`.
    /// @dev Under uninterrupted weakness the earliest ordinary cash->floor close is
    /// `holdCashPeriods + exitCashConfirmPeriods - 1`, the earliest ordinary extreme->cash close is
    /// `holdExtremePeriods + exitExtremeConfirmPeriods - 1`, and the earliest emergency descent is
    /// `lowVolumeResetPeriods`.
    function _computeNextModeV2(
        uint8 feeIdx,
        uint64 closeVol,
        uint96 emaVolScaled,
        bool bootstrapV2,
        uint8 holdRemaining,
        uint8 upExtremeStreak,
        uint8 downStreak,
        uint8 emergencyStreak
    ) internal view returns (ControllerTransitionResult memory result) {
        result.feeIdx = feeIdx;
        result.holdRemaining = holdRemaining;
        result.upExtremeStreak = upExtremeStreak;
        result.downStreak = downStreak;
        result.emergencyStreak = emergencyStreak;
        result.reasonCode = closeVol == 0 ? REASON_NO_SWAPS : REASON_NO_CHANGE;
        if (bootstrapV2) {
            result.decisionBits |= TRACE_FLAG_BOOTSTRAP_V2;
        }
        if (holdRemaining > 0) {
            result.decisionBits |= TRACE_FLAG_HOLD_WAS_ACTIVE;
        }

        // Hold counter is decremented before protection check; configured hold N gives N - 1 fully protected periods.
        if (result.holdRemaining > 0) {
            unchecked {
                result.holdRemaining -= 1;
            }
        }

        if (closeVol < _config.lowVolumeReset) {
            result.emergencyStreak = _incrementStreak(result.emergencyStreak, MAX_EMERGENCY_STREAK);
        } else {
            result.emergencyStreak = 0;
        }
        if (result.emergencyStreak >= _config.lowVolumeResetPeriods && result.feeIdx != MODE_FLOOR) {
            result.feeIdx = MODE_FLOOR;
            result.holdRemaining = 0;
            result.upExtremeStreak = 0;
            result.downStreak = 0;
            result.emergencyStreak = 0;
            result.reasonCode = REASON_EMERGENCY_FLOOR;
            result.decisionBits |= TRACE_FLAG_EMERGENCY_TRIGGERED;
            return result;
        }

        uint256 rBps =
            emaVolScaled == 0 ? 0 : (uint256(closeVol) * EMA_SCALE * BPS_SCALE) / uint256(emaVolScaled);

        if (result.feeIdx == MODE_FLOOR) {
            uint256 cashThreshold = uint256(_config.enterCashEmaRatioPct);
            bool cashEnterTriggered = rBps >= cashThreshold;
            if (cashEnterTriggered) {
                result.decisionBits |= TRACE_FLAG_CASH_ENTER_TRIGGER;
            }
            bool canJumpCash =
                !bootstrapV2
                    && emaVolScaled != 0
                    && closeVol >= _config.enterCashMinVolume
                    && cashEnterTriggered;
            if (canJumpCash && result.feeIdx != MODE_CASH) {
                result.feeIdx = MODE_CASH;
                result.holdRemaining = _config.holdCashPeriods;
                result.upExtremeStreak = 0;
                result.downStreak = 0;
                result.emergencyStreak = 0;
                result.reasonCode = REASON_JUMP_CASH;
                return result;
            }
        }

        if (result.feeIdx == MODE_CASH) {
            uint256 extremeThreshold = uint256(_config.enterExtremeEmaRatioPct);
            bool extremeEnterTriggered =
                closeVol >= _config.enterExtremeMinVolume && rBps >= extremeThreshold;
            if (extremeEnterTriggered) {
                result.decisionBits |= TRACE_FLAG_EXTREME_ENTER_TRIGGER;
            }
            if (extremeEnterTriggered) {
                result.upExtremeStreak = _incrementStreak(result.upExtremeStreak, MAX_UP_EXTREME_STREAK);
            } else {
                result.upExtremeStreak = 0;
            }
            if (
                !bootstrapV2 && result.upExtremeStreak >= _config.enterExtremeConfirmPeriods
                    && result.feeIdx != MODE_EXTREME
            ) {
                result.feeIdx = MODE_EXTREME;
                result.holdRemaining = _config.holdExtremePeriods;
                result.upExtremeStreak = 0;
                result.downStreak = 0;
                result.emergencyStreak = 0;
                result.reasonCode = REASON_JUMP_EXTREME;
                return result;
            }
        } else {
            result.upExtremeStreak = 0;
        }

        if (result.feeIdx == MODE_EXTREME) {
            if (rBps <= uint256(_config.exitExtremeEmaRatioPct)) {
                result.decisionBits |= TRACE_FLAG_EXTREME_EXIT_TRIGGER;
            }
        } else if (result.feeIdx == MODE_CASH) {
            if (rBps <= uint256(_config.exitCashEmaRatioPct)) {
                result.decisionBits |= TRACE_FLAG_CASH_EXIT_TRIGGER;
            }
        }

        if (result.holdRemaining > 0) {
            result.downStreak = 0;
            result.reasonCode = REASON_HOLD;
            return result;
        }

        if (result.feeIdx == MODE_EXTREME) {
            bool downExtremePass = rBps <= uint256(_config.exitExtremeEmaRatioPct);
            if (downExtremePass) {
                result.downStreak = _incrementStreak(result.downStreak, MAX_DOWN_STREAK);
            } else {
                result.downStreak = 0;
            }
            if (result.downStreak >= _config.exitExtremeConfirmPeriods) {
                result.downStreak = 0;
                if (result.feeIdx != MODE_CASH) {
                    result.feeIdx = MODE_CASH;
                    result.reasonCode = REASON_DOWN_TO_CASH;
                    return result;
                }
            }
        } else if (result.feeIdx == MODE_CASH) {
            bool downCashPass = rBps <= uint256(_config.exitCashEmaRatioPct);
            if (downCashPass) {
                result.downStreak = _incrementStreak(result.downStreak, MAX_DOWN_STREAK);
            } else {
                result.downStreak = 0;
            }
            if (result.downStreak >= _config.exitCashConfirmPeriods) {
                result.downStreak = 0;
                if (result.feeIdx != MODE_FLOOR) {
                    result.feeIdx = MODE_FLOOR;
                    result.reasonCode = REASON_DOWN_TO_FLOOR;
                    return result;
                }
            }
        } else {
            result.downStreak = 0;
        }

        if (bootstrapV2) {
            result.reasonCode = REASON_EMA_BOOTSTRAP;
        }
    }

    // -----------------------------------------------------------------------
    // Bit packing
    // -----------------------------------------------------------------------

    function _packState(
        uint64 periodVol,
        uint96 emaVolScaled,
        uint64 periodStart,
        uint8 feeIdx,
        bool paused,
        uint8 holdRemaining,
        uint8 upExtremeStreak,
        uint8 downStreak,
        uint8 emergencyStreak
    ) internal pure returns (uint256 packed) {
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

    function _unpackState(uint256 packed)
        internal
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
}
