#!/usr/bin/env bash
# One-time initialization of a deployed takumi_pay contract.
#
# Usage:
#   ./scripts/initialize.sh <network> <source-identity> <contract-id> <owner-address> <backend-signer-pubkey-hex>
#
# <backend-signer-pubkey-hex> is the 32-byte Ed25519 public key (64 hex
# chars, no 0x prefix) of the off-chain backend that will sign merchant
# payment quotes — see src/merchant.rs for the signing scheme.
set -euo pipefail
cd "$(dirname "$0")/.."

NETWORK="${1:?usage: initialize.sh <network> <source-identity> <contract-id> <owner-address> <backend-signer-pubkey-hex>}"
SOURCE="${2:?missing source-identity}"
CONTRACT_ID="${3:?missing contract-id}"
OWNER="${4:?missing owner-address}"
BACKEND_SIGNER="${5:?missing backend-signer-pubkey-hex}"

stellar contract invoke \
  --id "$CONTRACT_ID" \
  --source "$SOURCE" \
  --network "$NETWORK" \
  -- \
  initialize \
  --owner "$OWNER" \
  --backend_signer "$BACKEND_SIGNER"

echo "Initialized $CONTRACT_ID on $NETWORK with owner $OWNER"
