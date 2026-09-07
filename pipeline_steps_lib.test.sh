#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pipeline_steps_lib.sh
source "$DIR/pipeline_steps_lib.sh"

SENT_LOG="$(mktemp)"
trap 'rm -f "$SENT_LOG"' EXIT

run_with_retry() {
	shift 2
	printf '%s\n' "$*" >>"$SENT_LOG"
	return 0
}

L2_RPC_URL="http://127.0.0.1:8545"
L2_VAULT_PRIVATE_KEY="0x1111111111111111111111111111111111111111111111111111111111111111"
L2_ADDRESS="0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
CLAIM_SERVICE_ADDRESS="0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

step5_fund_l2_accounts

if ! grep -q -- '--value 6000ether 0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$SENT_LOG"; then
	echo "❌ 应给 L2_ADDRESS 转 6000 ether"
	cat "$SENT_LOG"
	exit 1
fi
if ! grep -q -- '--value 1000ether 0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$SENT_LOG"; then
	echo "❌ 应给 CLAIM_SERVICE_ADDRESS 转 1000 ether"
	cat "$SENT_LOG"
	exit 1
fi
if ! grep -q -- '--value 1000ether 0x311C290704B850d2be9aC5F486fD7073B7ce4Ad9' "$SENT_LOG"; then
	echo "❌ 应给固定地址 0x311C290704B850d2be9aC5F486fD7073B7ce4Ad9 转 1000 ether"
	cat "$SENT_LOG"
	exit 1
fi

echo "✅ step5_fund_l2_accounts 包含固定地址 1000 ETH 转账"
