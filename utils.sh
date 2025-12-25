#!/usr/bin/env bash

require_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || { echo "未找到 $cmd" >&2; return 1; }
}

run_with_retry() {
  local max_retries="$1"
  local delay_seconds="$2"
  shift 2

  local attempt=1
  local code=0
  while (( attempt <= max_retries )); do
    echo "尝试第 ${attempt}/${max_retries} 次执行: $*"

    # 注意：在开启 set -e 的脚本中，直接执行 "$@" 出错会导致整个脚本立刻退出；
    # 把命令放到 if 条件里执行，可以避免这一点，让我们自己控制重试逻辑。
    if "$@"; then
      echo "命令执行成功"
      return 0
    else
      code=$?
    fi

    if (( attempt == max_retries )); then
      echo "命令连续 ${max_retries} 次失败 (最后一次退出码=${code})，放弃重试"
      return "$code"
    fi

    echo "命令执行失败 (退出码=${code})，${delay_seconds} 秒后重试..."
    sleep "$delay_seconds"
    ((attempt++))
  done
}

check_template_substitution() {
  local file="$1"
  # shellcheck disable=SC2016  # 这里需要的是字面量模式 \${...}，而不是参数展开
  if grep -q '\${[A-Za-z_][A-Za-z0-9_]*}' "$file"; then
    echo "文件 $file 中仍存在未替换的模板变量，视为错误: $file" >&2
    return 1
  fi
}


