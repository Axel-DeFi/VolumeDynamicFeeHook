#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OPS_DIR="${PROJECT_ROOT}/ops"

explorer_base_url() {
  local chain="$1"
  case "$chain" in
    optimism)  echo "https://optimistic.etherscan.io" ;;
    sepolia)   echo "https://sepolia.etherscan.io" ;;
    *)         echo "" ;;
  esac
}

uniswap_chain_slug() {
  local chain="$1"
  case "$chain" in
    optimism)  echo "optimism" ;;
    sepolia)   echo "sepolia" ;;
    *)         echo "" ;;
  esac
}

compute_pool_id() {
  local volatile="$1"
  local stable="$2"
  local tick_spacing="$3"
  local hook="$4"
  local currency0 currency1

  # Sort tokens: lower address first
  if [[ "$(printf '%s' "$volatile" | tr '[:upper:]' '[:lower:]')" < "$(printf '%s' "$stable" | tr '[:upper:]' '[:lower:]')" ]]; then
    currency0="$volatile"
    currency1="$stable"
  else
    currency0="$stable"
    currency1="$volatile"
  fi

  local encoded
  encoded="$(cast abi-encode "f(address,address,uint24,int24,address)" \
    "$currency0" "$currency1" 8388608 "$tick_spacing" "$hook" 2>/dev/null)" || return 1
  cast keccak "$encoded" 2>/dev/null
}

usage() {
  cat <<'EOF'
Usage:
  ./scripts/deploy.sh --chain <network> --price <usd>

Required:
  --chain <network>   Target network (must have a config under ops/<network>/)
  --price <usd>       Current ETH price in USD for pool initialization

Example:
  ./scripts/deploy.sh --chain optimism --price 2182
EOF
}

list_configured_chains() {
  local chains=()
  for dir in "${OPS_DIR}"/*/; do
    local name
    name="$(basename "$dir")"
    [[ "$name" == "shared" || "$name" == "tests" || "$name" == "local" ]] && continue
    [[ -f "${dir}scripts/ensure-hook.sh" && -f "${dir}config/deploy.env" ]] || continue
    chains+=("$name")
  done
  printf '%s\n' "${chains[@]}"
}

CHAIN=""
PRICE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --chain)
      [[ $# -ge 2 ]] || { echo "Error: --chain requires a value" >&2; usage; exit 1; }
      CHAIN="$2"
      shift 2
      ;;
    --price)
      [[ $# -ge 2 ]] || { echo "Error: --price requires a value" >&2; usage; exit 1; }
      PRICE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$CHAIN" ]]; then
  echo "Error: --chain is required" >&2
  usage
  exit 1
fi

if [[ -z "$PRICE" ]]; then
  echo "Error: --price is required" >&2
  usage
  exit 1
fi

if ! [[ "$PRICE" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "Error: --price must be a positive number, got: $PRICE" >&2
  exit 1
fi

CHAIN_DIR="${OPS_DIR}/${CHAIN}"
DEPLOY_ENV="${CHAIN_DIR}/config/deploy.env"
ENSURE_HOOK="${CHAIN_DIR}/scripts/ensure-hook.sh"
ENSURE_POOL="${CHAIN_DIR}/scripts/ensure-pool.sh"
PREFLIGHT="${CHAIN_DIR}/scripts/preflight.sh"

if [[ ! -f "$ENSURE_HOOK" || ! -f "$DEPLOY_ENV" ]]; then
  echo "Error: network '${CHAIN}' is not configured for deployment." >&2
  echo "" >&2
  echo "Configured networks:" >&2
  while IFS= read -r name; do
    echo "  - ${name}" >&2
  done < <(list_configured_chains)
  exit 1
fi

echo "[deploy] chain: ${CHAIN}"
echo "[deploy] price: ${PRICE} USD"
echo ""

# Update INIT_PRICE_USD in deploy.env
if grep -q '^INIT_PRICE_USD=' "$DEPLOY_ENV"; then
  OLD_PRICE="$(grep '^INIT_PRICE_USD=' "$DEPLOY_ENV" | cut -d= -f2)"
  if [[ "$OLD_PRICE" != "$PRICE" ]]; then
    sed -i '' "s/^INIT_PRICE_USD=.*/INIT_PRICE_USD=${PRICE}/" "$DEPLOY_ENV"
    echo "[deploy] INIT_PRICE_USD updated: ${OLD_PRICE} -> ${PRICE}"
  else
    echo "[deploy] INIT_PRICE_USD already set to ${PRICE}"
  fi
else
  echo "INIT_PRICE_USD=${PRICE}" >> "$DEPLOY_ENV"
  echo "[deploy] INIT_PRICE_USD added: ${PRICE}"
fi

echo ""

# Phase 1: Preflight
echo "=== Phase 1/3: Preflight ==="
bash "$PREFLIGHT"
echo ""

# Phase 2: Deploy hook
echo "=== Phase 2/3: Deploy Hook ==="
bash "$ENSURE_HOOK"
echo ""

# Phase 3: Initialize pool
echo "=== Phase 3/3: Initialize Pool ==="
bash "$ENSURE_POOL"
echo ""

# Summary & links
STATE_FILE="${CHAIN_DIR}/out/state/${CHAIN}.addresses.json"
if [[ -f "$STATE_FILE" ]]; then
  echo "=== Deploy Complete ==="
  cat "$STATE_FILE"
  echo ""

  HOOK_ADDRESS="$(jq -r '.hookAddress // empty' "$STATE_FILE")"
  VOLATILE="$(jq -r '.volatileToken // empty' "$STATE_FILE")"
  STABLE="$(jq -r '.stableToken // empty' "$STATE_FILE")"

  EXPLORER="$(explorer_base_url "$CHAIN")"
  UNISWAP_SLUG="$(uniswap_chain_slug "$CHAIN")"
  TICK_SPACING="$(grep '^DEPLOY_TICK_SPACING=' "$DEPLOY_ENV" | cut -d= -f2)"

  if [[ -n "$HOOK_ADDRESS" && -n "$EXPLORER" ]]; then
    echo "=== Links ==="
    echo "Hook (explorer):  ${EXPLORER}/address/${HOOK_ADDRESS}"

    if [[ -n "$VOLATILE" && -n "$STABLE" && -n "$TICK_SPACING" && -n "$UNISWAP_SLUG" ]]; then
      POOL_ID="$(compute_pool_id "$VOLATILE" "$STABLE" "$TICK_SPACING" "$HOOK_ADDRESS")"
      if [[ -n "$POOL_ID" ]]; then
        echo "Pool (Uniswap):   https://app.uniswap.org/explore/pools/${UNISWAP_SLUG}/${POOL_ID}"
      fi
    fi
  fi
else
  echo "[deploy] warning: state file not found at ${STATE_FILE}"
fi
