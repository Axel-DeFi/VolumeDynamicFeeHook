#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"
source "${ROOT_DIR}/ops/shared/scripts/gas_common.sh"

load_local_config "gas"
gas_require_tools
gas_setup_paths "${OPS_LOCAL_DIR}" "local"

describe_operation() {
  case "$1" in
    normal_swap)
      printf '%s' 'Warm swap inside an open period; no close, no reset, no fee-tier change'
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
    close_gap_2_periods_cash_to_floor)
      printf '%s' 'Close 2 missed periods; ordinary CASH -> FLOOR after hold is already exhausted'
      ;;
    close_emergency_cash_to_floor)
      printf '%s' 'One measured close completes the low-volume emergency streak and resets CASH -> FLOOR'
      ;;
    idle_reset)
      printf '%s' 'Idle-time reset to FLOOR after inactivity'
      ;;
    close_gap_2_periods_no_transition)
      printf '%s' 'Close 2 missed periods; no fee-tier transition'
      ;;
    close_gap_8_periods_no_transition)
      printf '%s' 'Close 8 missed periods; no fee-tier transition'
      ;;
    close_gap_23_periods_no_transition)
      printf '%s' 'Close 23 missed periods; no fee-tier transition'
      ;;
    close_gap_2_periods_with_floor_to_cash)
      printf '%s' 'Close 2 missed periods; includes FLOOR -> CASH transition inside the gap close'
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
      close_one_period_no_transition \
      close_one_period_floor_to_cash \
      close_one_period_cash_to_floor \
      close_gap_2_periods_cash_to_floor \
      close_emergency_cash_to_floor \
      idle_reset \
      close_gap_2_periods_no_transition \
      close_gap_8_periods_no_transition \
      close_gap_23_periods_no_transition \
      close_gap_2_periods_with_floor_to_cash
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

runs="${OPS_GAS_RUNS:-5}"
chain_id="${CHAIN_ID_EXPECTED:-31337}"
report_test_path='ops/tests/unit/MeasureGasLocalReport.t.sol'
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

rm -f "${tmp_output}" "${tmp_samples}"

echo "gas samples: ${OPS_GAS_SAMPLES_PATH}"
echo "gas report json: ${OPS_GAS_REPORT_JSON}"
echo "gas report md: ${OPS_GAS_REPORT_MD}"
