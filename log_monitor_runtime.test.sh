#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export YDYL_LOG_MONITOR_SOURCE_ONLY=1
source "$SCRIPT_DIR/log_monitor_runtime.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "$haystack" != *"$needle"* ]]; then
    fail "expected output to contain: $needle"
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "$haystack" == *"$needle"* ]]; then
    fail "expected output not to contain: $needle"
  fi
}

assert_service_matches() {
  local stack="$1"
  local service="$2"
  local regex
  regex="$(kurtosis_service_name_regex "$stack")"
  if ! grep -Eq "$regex" <<<"$service"; then
    fail "expected $stack service whitelist to match: $service"
  fi
}

assert_service_not_matches() {
  local stack="$1"
  local service="$2"
  local regex
  regex="$(kurtosis_service_name_regex "$stack")"
  if grep -Eq "$regex" <<<"$service"; then
    fail "expected $stack service whitelist not to match: $service"
  fi
}

test_cdk_service_whitelist() {
  assert_service_matches cdk "cdk-node-1"
  assert_service_matches cdk "cdk-erigon-rpc-1"
  assert_service_matches cdk "cdk-erigon-sequencer-1"
  assert_service_matches cdk "zkevm-pool-manager-1"
  assert_service_matches cdk "zkevm-prover-1"
  assert_service_matches cdk "status-checker-1"
  assert_service_matches cdk "zkevm-bridge-service-1"
  assert_service_not_matches cdk "contracts-1"
  assert_service_not_matches cdk "postgres-1"
  assert_service_not_matches cdk "panoptichain-1"
  assert_service_not_matches cdk "grafana-1"
}

test_op_service_whitelist() {
  assert_service_matches op "op-cl-1-op-node-op-geth-op-kurtosis"
  assert_service_matches op "op-el-1-op-geth-op-node-op-kurtosis"
  assert_service_matches op "op-batcher-op-kurtosis"
  assert_service_matches op "op-proposer-op-kurtosis"
  assert_service_matches op "op-challenger-op-kurtosis"
  assert_service_not_matches op "grafana"
  assert_service_not_matches op "prometheus"
  assert_service_not_matches op "op-blockscoutop-kurtosis"
}

test_cdk_log_filter() {
  local input output
  input=$'[cdk-node-1] 2026-06-11T03:54:01.260Z\tDEBUG\treorgdetector/reorgdetector.go:154\tChecking reorgs\n[status-checker-1] 2026-06-11T03:54:02.000Z\tINFO\tstatus ok\n[zkevm-bridge-service-1] 2026-06-11T03:54:03.000Z\tWARN\tbridge retry\n[contracts-1] 2026-06-11T03:54:04.000Z\tERROR\tcontracts noise\n[cdk-erigon-rpc-1] [dbg] noisy erigon row\n[cdk-erigon-sequencer-1] [INFO] sequencer imported block'
  output="$(filter_kurtosis_log_lines cdk <<<"$input")"

  assert_contains "$output" "[status-checker-1]"
  assert_contains "$output" "[zkevm-bridge-service-1]"
  assert_contains "$output" "[cdk-erigon-sequencer-1]"
  assert_not_contains "$output" "[cdk-node-1]"
  assert_not_contains "$output" "[contracts-1]"
  assert_not_contains "$output" "[cdk-erigon-rpc-1]"
}

test_op_log_filter() {
  local input output
  input=$'[op-cl-1-op-node-op-geth-op-kurtosis] t="2026-06-11 03:34:03.001" lvl=debug msg="[Sequencer] received BuildStartedEvent"\n[op-el-1-op-geth-op-node-op-kurtosis] t="2026-06-11 03:34:04.001" lvl=info msg="Imported new block"\n[op-batcher-op-kurtosis] t="2026-06-11 03:34:05.001" lvl=trace msg="trace noise"\n[op-proposer-op-kurtosis] t="2026-06-11 03:34:06.001" lvl=warn msg="proposal delayed"\n[grafana] lvl=error msg="dashboard noise"'
  output="$(filter_kurtosis_log_lines op <<<"$input")"

  assert_contains "$output" "[op-el-1-op-geth-op-node-op-kurtosis]"
  assert_contains "$output" "[op-proposer-op-kurtosis]"
  assert_not_contains "$output" "[op-cl-1-op-node-op-geth-op-kurtosis]"
  assert_not_contains "$output" "[op-batcher-op-kurtosis]"
  assert_not_contains "$output" "[grafana]"
}

test_cdk_service_whitelist
test_op_service_whitelist
test_cdk_log_filter
test_op_log_filter

echo "PASS: log_monitor_runtime filters"
