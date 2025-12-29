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


