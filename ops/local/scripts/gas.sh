#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"
source "${ROOT_DIR}/ops/shared/scripts/gas_common.sh"

load_local_config "gas"
gas_require_tools
gas_setup_paths "${OPS_LOCAL_DIR}" "local"

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

rm -f "${tmp_output}" "${tmp_samples}"

echo "gas samples: ${OPS_GAS_SAMPLES_PATH}"
echo "gas report json: ${OPS_GAS_REPORT_JSON}"
echo "gas report md: ${OPS_GAS_REPORT_MD}"
