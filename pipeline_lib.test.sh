#!/bin/bash
set -euo pipefail

# 简单测试脚本，用于验证 pipeline_lib.sh 的核心行为

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/pipeline_lib.sh"

TEST_TMP_DIR="$DIR/output/pipeline_lib_test"
mkdir -p "$TEST_TMP_DIR"
STATE_FILE="$TEST_TMP_DIR/state.test"

pass() { echo "✅ $*"; }
fail() { echo "❌ $*"; exit 1; }

assert_eq() {
  local expected="$1"
  local actual="$2"
  local msg="${3:-}"
  if [ "$expected" != "$actual" ]; then
    fail "断言失败: $msg 期望='$expected', 实际='$actual'"
  fi
}

echo "== 清理旧状态文件 =="
rm -f "$STATE_FILE"

########################################
# 测试 1: pipeline_load_state + save_state
########################################

echo "== 测试 1: pipeline_load_state + save_state =="

PERSIST_VARS=(
  FOO
  BAR
)

FOO="foo_value"
BAR="bar_value"

pipeline_load_state
assert_eq "0" "$LAST_DONE_STEP" "初始 LAST_DONE_STEP 应为 0"

save_state 3
[ -f "$STATE_FILE" ] || fail "状态文件未生成: $STATE_FILE"

# 模拟新进程加载状态
unset FOO BAR LAST_DONE_STEP
pipeline_load_state

assert_eq "3" "$LAST_DONE_STEP" "加载状态后 LAST_DONE_STEP 应为 3"
assert_eq "foo_value" "$FOO" "加载状态后 FOO 应为持久化值"
assert_eq "bar_value" "$BAR" "加载状态后 BAR 应为持久化值"

pass "测试 1 通过"

########################################
# 测试 2: pipeline_parse_start_step
########################################

echo "== 测试 2: pipeline_parse_start_step =="

LAST_DONE_STEP=5
unset START_STEP
pipeline_parse_start_step
assert_eq "6" "$START_STEP" "未指定 START_STEP 时应从 LAST_DONE_STEP+1 开始"

START_STEP=10
pipeline_parse_start_step
assert_eq "10" "$START_STEP" "显式指定 START_STEP 时应保留该值"

unset START_STEP
pipeline_parse_start_step 7
assert_eq "7" "$START_STEP" "第一个参数为起始步骤时应生效"

pass "测试 2 通过"

########################################
# 测试 3: run_step 跳过与执行
########################################

echo "== 测试 3: run_step 跳过与执行 =="

PERSIST_VARS=( STEP_EXEC_LOG )
STEP_EXEC_LOG=""
STATE_FILE="$TEST_TMP_DIR/state.run_step"
rm -f "$STATE_FILE"
pipeline_load_state

START_STEP=2

step_fn() {
  local id="$1"
  STEP_EXEC_LOG+="$id,"
}

run_step 1 "should be skipped" step_fn "A"
run_step 2 "should run"        step_fn "B"
run_step 3 "should run"        step_fn "C"

assert_eq ",B,C," ",$STEP_EXEC_LOG" "STEP_EXEC_LOG 中应只包含 B,C"

pipeline_load_state
assert_eq "3" "$LAST_DONE_STEP" "run_step 后 LAST_DONE_STEP 应为最后执行的步骤 3"

pass "测试 3 通过"

########################################
# 测试 4: check_input_env_consistency 一致与不一致
########################################

echo "== 测试 4: check_input_env_consistency 一致与不一致 =="

STATE_FILE="$TEST_TMP_DIR/state.env_compat"
PERSIST_VARS=( L1_CHAIN_ID )
L1_CHAIN_ID="10086"
save_state 1

# 一致情况：不应报错
INPUT_L1_CHAIN_ID="10086"
check_input_env_consistency L1_CHAIN_ID
pass "check_input_env_consistency 一致情况通过"

# 不一致情况：在子进程中调用，预期非 0 退出
INPUT_L1_CHAIN_ID="99999"
if ( check_input_env_consistency L1_CHAIN_ID ); then
  fail "check_input_env_consistency 不一致情况测试失败（未检测到错误）"
fi

pass "测试 4 通过（包含不一致情况）"

echo "🎉 所有 pipeline_lib.sh 测试通过"


