#!/usr/bin/env bash
# Builds the takumi_pay Soroban contract to an optimized WASM binary.
#
# Requires the `stellar` CLI (https://developers.stellar.org/docs/build/smart-contracts/getting-started/setup)
# and the wasm32v1-none Rust target:
#   rustup target add wasm32v1-none
set -euo pipefail
cd "$(dirname "$0")/.."

stellar contract build --package takumi-pay

WASM_PATH="target/wasm32v1-none/release/takumi_pay.wasm"
stellar contract optimize --wasm "$WASM_PATH"

echo "Built: $WASM_PATH"
echo "Optimized: target/wasm32v1-none/release/takumi_pay.optimized.wasm"
