#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"
source "${ROOT_DIR}/ops/shared/scripts/gas_common.sh"

load_local_config "gas"
gas_require_tools
require_cmd git
gas_setup_paths "${OPS_LOCAL_DIR}" "local"

describe_operation() {
  case "$1" in
    normal_swap)
      printf '%s' 'Warm swap inside an open period; no close, no reset, no fee-tier change'
      ;;
    claim_hook_fees_one_chunk)
      printf '%s' 'Full HookFee claim settled in one PoolManager chunk'
      ;;
    close_one_period_no_transition)
      printf '%s' 'One elapsed-period close; no fee-tier transition'
      ;;
    close_one_period_floor_to_cash)
      printf '%s' 'One elapsed-period close; FLOOR -> CASH transition with LP fee sync'
      ;;
    close_one_period_cash_to_floor)
      printf '%s' 'One elapsed-period close; ordinary CASH -> FLOOR after hold exhaustion'
      ;;
    close_one_period_cash_to_extreme)
      printf '%s' 'One elapsed-period close; ordinary CASH -> EXTREME after confirm buildup'
      ;;
    close_one_period_extreme_to_cash)
      printf '%s' 'One elapsed-period close; ordinary EXTREME -> CASH after hold exhaustion'
      ;;
    close_emergency_cash_to_floor)
      printf '%s' 'One measured close completes the low-volume emergency streak and resets CASH -> FLOOR'
      ;;
    close_emergency_extreme_to_floor)
      printf '%s' 'One measured close completes the low-volume emergency streak and resets EXTREME -> FLOOR'
      ;;
    idle_reset)
      printf '%s' 'Idle-time reset to FLOOR after inactivity'
      ;;
    close_one_period_cash_hold_blocks_floor)
      printf '%s' 'One elapsed-period close; hold blocks ordinary CASH -> FLOOR'
      ;;
    close_one_period_extreme_hold_blocks_cash)
      printf '%s' 'One elapsed-period close; hold blocks ordinary EXTREME -> CASH'
      ;;
    close_gap_2_periods_no_transition)
      printf '%s' 'Close 2 missed periods; no fee-tier transition'
      ;;
    close_gap_8_periods_no_transition)
      printf '%s' 'Close 8 missed periods; no fee-tier transition'
      ;;
    close_gap_max_periods_no_transition)
      printf '%s' 'Close max missed periods below idle-reset threshold; no fee-tier transition'
      ;;
    close_gap_2_periods_with_floor_to_cash)
      printf '%s' 'Close 2 missed periods; includes FLOOR -> CASH transition inside the gap close'
      ;;
    close_gap_2_periods_with_cash_to_floor)
      printf '%s' 'Close 2 missed periods; includes ordinary CASH -> FLOOR transition inside the gap close'
      ;;
    close_gap_2_periods_with_cash_to_extreme)
      printf '%s' 'Close 2 missed periods; includes CASH -> EXTREME transition inside the gap close'
      ;;
    close_gap_2_periods_with_extreme_to_cash)
      printf '%s' 'Close 2 missed periods; includes ordinary EXTREME -> CASH transition inside the gap close'
      ;;
    close_gap_2_periods_with_emergency_cash_to_floor)
      printf '%s' 'Close 2 missed periods; gap close completes the low-volume emergency CASH -> FLOOR reset'
      ;;
    close_gap_2_periods_with_emergency_extreme_to_floor)
      printf '%s' 'Close 2 missed periods; gap close completes the low-volume emergency EXTREME -> FLOOR reset'
      ;;
    close_one_period_no_swaps_no_transition)
      printf '%s' 'One elapsed-period close with no swaps; no fee-tier transition'
      ;;
    close_one_period_no_swaps_seeded)
      printf '%s' 'One elapsed-period close with no swaps; starts from a seeded open-period baseline'
      ;;
    close_gap_2_periods_no_swaps_no_transition)
      printf '%s' 'Close 2 missed no-swap periods; no fee-tier transition'
      ;;
    close_gap_2_periods_no_swaps_seeded)
      printf '%s' 'Close 2 missed no-swap periods; starts from a seeded open-period baseline'
      ;;
    close_gap_2_periods_cash_hold_blocks_floor)
      printf '%s' 'Close 2 missed periods; hold blocks ordinary CASH -> FLOOR during the gap close'
      ;;
    close_gap_2_periods_extreme_hold_blocks_cash)
      printf '%s' 'Close 2 missed periods; hold blocks ordinary EXTREME -> CASH during the gap close'
      ;;
    *)
      printf '%s' 'Measured path'
      ;;
  esac
}

format_vs_baseline() {
  local avg_gas="$1"
  local baseline_gas="$2"

  if [[ "${avg_gas}" == "${baseline_gas}" ]]; then
    printf '%s' 'baseline'
    return 0
  fi

  awk -v avg="${avg_gas}" -v base="${baseline_gas}" \
    'BEGIN { delta = avg - base; pct = (delta / base) * 100; printf "%+d / %+0.1f%%", delta, pct }'
}

append_scenario_summary() {
  local baseline_avg
  baseline_avg="$(jq -r '.operations[] | select(.operation == "normal_swap") | .avgGasUsed' "${OPS_GAS_REPORT_JSON}")"

  {
    printf '\n## Scenario Summary\n\n'
    printf '| Operation | Path | Avg gas | Vs baseline |\n'
    printf '|---|---|---:|---:|\n'

    for operation in \
      normal_swap \
      claim_hook_fees_one_chunk \
      close_one_period_no_transition \
      close_one_period_floor_to_cash \
      close_one_period_cash_to_floor \
      close_one_period_cash_to_extreme \
      close_one_period_extreme_to_cash \
      close_emergency_cash_to_floor \
      close_emergency_extreme_to_floor \
      idle_reset \
      close_one_period_cash_hold_blocks_floor \
      close_one_period_extreme_hold_blocks_cash \
      close_gap_2_periods_no_transition \
      close_gap_8_periods_no_transition \
      close_gap_max_periods_no_transition \
      close_gap_2_periods_with_floor_to_cash \
      close_gap_2_periods_with_cash_to_floor \
      close_gap_2_periods_with_cash_to_extreme \
      close_gap_2_periods_with_extreme_to_cash \
      close_gap_2_periods_with_emergency_cash_to_floor \
      close_gap_2_periods_with_emergency_extreme_to_floor \
      close_one_period_no_swaps_no_transition \
      close_one_period_no_swaps_seeded \
      close_gap_2_periods_no_swaps_no_transition \
      close_gap_2_periods_no_swaps_seeded \
      close_gap_2_periods_cash_hold_blocks_floor \
      close_gap_2_periods_extreme_hold_blocks_cash
    do
      local avg_gas
      avg_gas="$(jq -r --arg op "${operation}" '.operations[] | select(.operation == $op) | .avgGasUsed' "${OPS_GAS_REPORT_JSON}")"
      [[ -n "${avg_gas}" && "${avg_gas}" != "null" ]] || continue

      printf '| `%s` | %s | %s | %s |\n' \
        "${operation}" \
        "$(describe_operation "${operation}")" \
        "${avg_gas}" \
        "$(format_vs_baseline "${avg_gas}" "${baseline_avg}")"
    done
  } >> "${OPS_GAS_REPORT_MD}"
}

runs="${OPS_GAS_RUNS:-10}"
chain_id="${CHAIN_ID_EXPECTED:-31337}"
report_test_path='ops/tests/unit/MeasureGasLocalReport.t.sol'
timing_path="${OPS_LOCAL_DIR}/out/reports/gas.local.timing.json"
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
start_epoch="$(date +%s)"
command="OPS_GAS_RUNS=${runs} ops/local/scripts/gas.sh"
git_commit_start="$(git rev-parse HEAD)"
tmp_output="$(mktemp)"
tmp_samples="$(mktemp)"
: > "${tmp_samples}"

for run in $(seq 1 "${runs}"); do
  forge test --offline --match-path "${report_test_path}" | tee "${tmp_output}"

  while IFS=$'\t' read -r operation gas_used; do
    jq -cn \
      --arg network "local" \
      --argjson chainId "${chain_id}" \
      --arg operation "${operation}" \
      --argjson run "${run}" \
      --arg txHash "" \
      --argjson gasUsed "${gas_used}" \
      --argjson effectiveGasPriceWei 0 \
      '{
        network: $network,
        chainId: $chainId,
        operation: $operation,
        run: $run,
        txHash: $txHash,
        gasUsed: $gasUsed,
        effectiveGasPriceWei: $effectiveGasPriceWei
      }' >> "${tmp_samples}"
  done < <(
    awk '
      /^\[PASS\] testGas_/ {
        if (match($0, /testGas_[A-Za-z0-9_]+/)) {
          fn = substr($0, RSTART, RLENGTH)
        } else {
          next
        }
        if (match($0, /\(gas: [0-9]+\)/)) {
          gas = substr($0, RSTART, RLENGTH)
          gsub(/\(gas: /, "", gas)
          gsub(/\)/, "", gas)
        } else {
          next
        }
        op = fn
        sub(/^testGas_/, "", op)
        print op "\t" gas
      }
    ' "${tmp_output}"
  )
done

jq -s '.' "${tmp_samples}" > "${OPS_GAS_SAMPLES_PATH}"
gas_render_reports_from_samples_file "local" "${chain_id}" "${runs}" "${OPS_GAS_SAMPLES_PATH}"
append_scenario_summary

ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
end_epoch="$(date +%s)"
elapsed_seconds="$((end_epoch - start_epoch))"
elapsed_hms="$(printf '%02d:%02d:%02d' $((elapsed_seconds / 3600)) $(((elapsed_seconds % 3600) / 60)) $((elapsed_seconds % 60)))"
git_commit_end="$(git rev-parse HEAD)"

if [[ "${git_commit_start}" != "${git_commit_end}" ]]; then
  echo "ERROR: git HEAD changed during benchmark run: ${git_commit_start} -> ${git_commit_end}" >&2
  exit 1
fi

jq -n \
  --arg startedAt "${started_at}" \
  --arg endedAt "${ended_at}" \
  --arg command "${command}" \
  --arg gitCommit "${git_commit_start}" \
  --argjson runs "${runs}" \
  --argjson elapsedSeconds "${elapsed_seconds}" \
  --arg elapsedHms "${elapsed_hms}" \
  --arg reportJson "${OPS_GAS_REPORT_JSON}" \
  --arg reportMd "${OPS_GAS_REPORT_MD}" \
  --arg samplesJson "${OPS_GAS_SAMPLES_PATH}" \
  '{
    startedAt: $startedAt,
    endedAt: $endedAt,
    elapsedSeconds: $elapsedSeconds,
    elapsedHms: $elapsedHms,
    runs: $runs,
    command: $command,
    gitCommit: $gitCommit,
    reportJson: $reportJson,
    reportMd: $reportMd,
    samplesJson: $samplesJson
  }' > "${timing_path}"

rm -f "${tmp_output}" "${tmp_samples}"

echo "gas samples: ${OPS_GAS_SAMPLES_PATH}"
echo "gas report json: ${OPS_GAS_REPORT_JSON}"
echo "gas report md: ${OPS_GAS_REPORT_MD}"
echo "timing json: ${timing_path}"
