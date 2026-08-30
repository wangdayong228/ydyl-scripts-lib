#!/bin/bash
set -euo pipefail

# 引入 utils.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UTILS_PATH="$SCRIPT_DIR/utils.sh"
if [[ ! -f "$UTILS_PATH" ]]; then
  echo "找不到 utils.sh 文件"
  exit 1
fi
source "$UTILS_PATH"

# 用于模拟会失败的命令
fail_count=0
max_fail=2

fake_cmd() {
  if [[ $fail_count -lt $max_fail ]]; then
    ((fail_count++))
    echo "模拟失败 ($fail_count/$max_fail)"
    return 1
  else
    echo "模拟成功 ($fail_count/$max_fail)"
    return 0
  fi
}

echo "===== 测试 run_with_retry 成功情况 ====="
fail_count=0
if run_with_retry 3 1 fake_cmd; then
  echo "✅ 测试通过: 成功重试后命令执行通过"
else
  echo "❌ 测试失败: 命令应该成功但最终执行失败"
  exit 1
fi

echo "===== 测试 run_with_retry 达到最大重试次数仍然失败 ====="
fail_count=0
max_fail=10
if run_with_retry 3 1 fake_cmd; then
  echo "❌ 测试失败: 命令应该失败但返回成功"
  exit 1
else
  echo "✅ 测试通过: 重试超限后命令失败"
fi

echo "全部 run_with_retry 测试用例通过"

echo "===== 测试 check_template_substitution 成功情况（无占位符） ====="
tmp_ok="$(mktemp)"
cat > "$tmp_ok" <<'EOF'
KEY1=value1
KEY2=value2
EOF

if check_template_substitution "$tmp_ok"; then
  echo "✅ 测试通过: 无占位符文件被视为成功"
else
  echo "❌ 测试失败: 无占位符文件被误判为失败"
  rm -f "$tmp_ok"
  exit 1
fi
rm -f "$tmp_ok"

echo "===== 测试 check_template_substitution 失败情况（仍有占位符） ====="
tmp_bad="$(mktemp)"
cat > "$tmp_bad" <<'EOF'
KEY1=value1
UNFILLED_VAR=${SHOULD_BE_REPLACED}
EOF

if bash -c "source '$UTILS_PATH'; check_template_substitution '$tmp_bad'" 2>/dev/null; then
  echo "❌ 测试失败: 仍有占位符应当导致函数退出非零"
  rm -f "$tmp_bad"
  exit 1
else
  echo "✅ 测试通过: 检测到未替换占位符并退出非零"
fi
rm -f "$tmp_bad"

echo "全部 utils.sh 测试用例通过"

echo "===== 测试 wei_deficit ====="

assert_wei_deficit() {
  local expected="$1"
  local current="$2"
  local target="$3"
  local msg="${4:-}"
  local actual
  actual=$(wei_deficit "$current" "$target")
  if [[ "$expected" != "$actual" ]]; then
    echo "❌ wei_deficit 断言失败: $msg 期望='$expected', 实际='$actual'"
    exit 1
  fi
}

# 不足
assert_wei_deficit "500" "1000" "1500" "差额 500"
# 恰好达标
assert_wei_deficit "0" "1000" "1000" "已达标"
# 超额
assert_wei_deficit "0" "2000" "1000" "超额不抽回"
# 5000 ether 量级（5e21 wei）
assert_wei_deficit "1000000000000000000000" "4000000000000000000000" "5000000000000000000000" "5000 ether 大整数"

echo "✅ wei_deficit 测试通过"

echo "===== 测试 fund_eth_up_to（假 cast） ====="

FAKE_BIN_DIR="$(mktemp -d)"
trap 'rm -rf "$FAKE_BIN_DIR"' EXIT

cat > "$FAKE_BIN_DIR/cast" <<'EOF'
#!/bin/bash
case "$1" in
  balance)
    if [[ "${FAKE_BALANCE_FAIL:-}" = "true" ]]; then
      echo "balance query failed" >&2
      exit 1
    fi
    echo "${FAKE_BALANCE:-0}"
    ;;
  to-wei)
    # 仅支持测试中的 1000 ether / 5000 ether
    if [[ "$3" == "ether" ]]; then
      case "$2" in
        1000) echo "1000000000000000000000" ;;
        5000) echo "5000000000000000000000" ;;
        *) echo "unsupported amount: $2" >&2; exit 1 ;;
      esac
    else
      echo "unsupported unit: $3" >&2; exit 1
    fi
    ;;
  send)
    echo "SEND:$*" >> "${FAKE_CAST_SEND_LOG:-/dev/null}"
    ;;
  *)
    echo "unsupported cast command: $1" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$FAKE_BIN_DIR/cast"

PATH="$FAKE_BIN_DIR:$PATH"
FAKE_CAST_SEND_LOG="$(mktemp)"
export FAKE_CAST_SEND_LOG

# 已达标：跳过 send
: > "$FAKE_CAST_SEND_LOG"
FAKE_BALANCE="1000000000000000000000"
export FAKE_BALANCE
if fund_eth_up_to "http://fake-rpc" "0xdead" "0xrecipient" 1000 ether; then
  if [[ -s "$FAKE_CAST_SEND_LOG" ]]; then
    echo "❌ fund_eth_up_to 已达标时不应 send"
    exit 1
  fi
  echo "✅ fund_eth_up_to 已达标跳过"
else
  echo "❌ fund_eth_up_to 已达标时应成功返回"
  exit 1
fi

# 不足：只转差额
: > "$FAKE_CAST_SEND_LOG"
FAKE_BALANCE="400000000000000000000"
export FAKE_BALANCE
if fund_eth_up_to "http://fake-rpc" "0xdead" "0xrecipient" 1000 ether; then
  if ! grep -q 'SEND:.*--value 600000000000000000000wei' "$FAKE_CAST_SEND_LOG"; then
    echo "❌ fund_eth_up_to 应只转差额 600000000000000000000 wei"
    cat "$FAKE_CAST_SEND_LOG"
    exit 1
  fi
  echo "✅ fund_eth_up_to 只转差额"
else
  echo "❌ fund_eth_up_to 补足差额时应成功"
  exit 1
fi

# DRYRUN：不 send
: > "$FAKE_CAST_SEND_LOG"
FAKE_BALANCE="0"
export FAKE_BALANCE
DRYRUN=true
export DRYRUN
if fund_eth_up_to "http://fake-rpc" "0xdead" "0xrecipient" 5000 ether; then
  if [[ -s "$FAKE_CAST_SEND_LOG" ]]; then
    echo "❌ DRYRUN 模式下不应 send"
    exit 1
  fi
  echo "✅ fund_eth_up_to DRYRUN 不执行转账"
else
  echo "❌ fund_eth_up_to DRYRUN 应成功返回"
  exit 1
fi

unset DRYRUN
rm -f "$FAKE_CAST_SEND_LOG"

# DRYRUN + balance 查询失败：应失败，不能误报成功
: > "$FAKE_CAST_SEND_LOG"
unset FAKE_BALANCE
FAKE_BALANCE_FAIL=true
export FAKE_BALANCE_FAIL
DRYRUN=true
export DRYRUN
if fund_eth_up_to "http://fake-rpc" "0xdead" "0xrecipient" 1000 ether; then
  echo "❌ DRYRUN 下 balance 查询失败时不应返回成功"
  exit 1
else
  echo "✅ fund_eth_up_to DRYRUN 在 balance 失败时正确失败"
fi

unset DRYRUN FAKE_BALANCE_FAIL
rm -f "$FAKE_CAST_SEND_LOG"

echo "全部 fund_eth_up_to 测试用例通过"

echo "===== 测试 require_non_negative_int_env ====="

assert_int_env() {
  local expected="$1"
  local var_name="$2"
  local default_val="$3"
  local env_val="${4-}"
  local actual
  if [[ -n "${env_val+x}" ]]; then
    export "${var_name?}=${env_val}"
  else
    unset "${var_name?}" 2>/dev/null || true
  fi
  actual=$(require_non_negative_int_env "$var_name" "$default_val")
  if [[ "$expected" != "$actual" ]]; then
    echo "❌ require_non_negative_int_env 断言失败: 期望='$expected', 实际='$actual'"
    exit 1
  fi
}

assert_int_env_fail() {
  local var_name="$1"
  local default_val="$2"
  local env_val="$3"
  export "${var_name?}=${env_val}"
  if require_non_negative_int_env "$var_name" "$default_val" 2>/dev/null; then
    echo "❌ require_non_negative_int_env 应失败: ${var_name}=${env_val}"
    exit 1
  fi
}

assert_int_env "5000" "L1_FUND_VAULT_ETH" 5000
assert_int_env "100" "L1_FUND_VAULT_ETH" 5000 "100"
assert_int_env "0" "L1_FUND_CLAIM_SERVICE_ETH" 1000 "0"
assert_int_env_fail "L1_FUND_VAULT_ETH" 5000 "-1"
assert_int_env_fail "L1_FUND_VAULT_ETH" 5000 "1.5"
assert_int_env_fail "L1_FUND_VAULT_ETH" 5000 "abc"

echo "✅ require_non_negative_int_env 测试通过"


