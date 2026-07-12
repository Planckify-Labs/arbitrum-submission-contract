#!/usr/bin/env bash
# Deploys the takumi_pay contract WASM to a Stellar network and records the
# result under deployments/<network>/.
#
# Usage:
#   ./scripts/deploy.sh <testnet|mainnet> <source-identity>
#
# <source-identity> is a name already registered with `stellar keys generate`
# (or `stellar keys add` for an existing key) and, for testnet, funded via
# `stellar keys fund <source-identity> --network testnet`.
set -euo pipefail
cd "$(dirname "$0")/.."

NETWORK="${1:?usage: deploy.sh <testnet|mainnet> <source-identity>}"
SOURCE="${2:?usage: deploy.sh <testnet|mainnet> <source-identity>}"

./scripts/build.sh

WASM_PATH="target/wasm32v1-none/release/takumi_pay.optimized.wasm"

CONTRACT_ID=$(stellar contract deploy \
  --wasm "$WASM_PATH" \
  --source "$SOURCE" \
  --network "$NETWORK")

echo "Deployed takumi_pay to $NETWORK: $CONTRACT_ID"

OUT_DIR="deployments/$NETWORK"
mkdir -p "$OUT_DIR"

# Version = count of existing deployment records + 1, matching the sui/
# deployments/<network>/vN.json convention used elsewhere in this repo.
EXISTING=$(find "$OUT_DIR" -maxdepth 1 -name 'v*.json' 2>/dev/null | wc -l | tr -d ' ')
VERSION=$((EXISTING + 1))
OUT_FILE="$OUT_DIR/v${VERSION}.json"

cat > "$OUT_FILE" <<EOF
{
  "network": "$NETWORK",
  "version": $VERSION,
  "contractId": "$CONTRACT_ID",
  "deployer": "$SOURCE",
  "publishedAt": "$(date -u +%Y-%m-%d)",
  "wasm": "takumi_pay.optimized.wasm"
}
EOF

echo "Recorded deployment: $OUT_FILE"
echo
echo "Next: initialize the contract with an owner + backend signer:"
echo "  ./scripts/initialize.sh $NETWORK $SOURCE $CONTRACT_ID <owner-address> <backend-signer-pubkey-hex>"
