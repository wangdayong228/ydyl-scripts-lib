#!/usr/bin/env bash

require_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || { echo "未找到 $cmd" >&2; return 1; }
}

require_commands() {
  local cmd
  for cmd in "$@"; do
    require_command "$cmd" || return 1
  done
}

require_file() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    echo "文件不存在: $f" >&2
    return 1
  fi
}

require_var() {
    local var_name="$1"
    local var_value="${!var_name-}"
    if [[ -z "${var_value:-}" ]]; then
        echo "错误: $var_name 为空或未设置" >&2
        return 1
    fi
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

########################################
# PM2 工具：检查是否有进程处于 error 状态；非 error 即视为成功
########################################

# 内部实现函数：不控制 xtrace，只负责逻辑
_pm2_check_all_unerror_impl() {
  local namespace="${1:-}"
  local jq_filter='.[]'

  if [[ -n "$namespace" ]]; then
    jq_filter='.[] | select(.pm2_env.namespace=="'"$namespace"'")'
  fi

  # 把 pm2 的 stderr 丢掉，避免非 JSON 干扰 jq
  local jlist
  if ! jlist=$(pm2 jlist --silent 2>/dev/null); then
    echo "🔴 pm2 jlist 执行失败，可能 pm2 本身有问题" >&2
    return 1
  fi

  local bad
  if ! bad=$(printf '%s\n' "$jlist" \
    | jq -r "$jq_filter | select(.pm2_env.status == \"errored\") | \"\(.name) [ns=\(.pm2_env.namespace // \"-\")] status=\(.pm2_env.status)\""
  ); then
    echo "🔴 解析 pm2 jlist 输出失败（jq 报错），请单独运行 'pm2 jlist' 查看原始输出" >&2
    return 1
  fi

  if [[ -n "$bad" ]]; then
    echo "🔴 以下 PM2 进程处于 error 状态：" >&2
    echo "$bad" >&2
    echo "请用 'pm2 logs <name>' 查看具体错误日志。" >&2
    return 1
  fi

  if [[ -n "$namespace" ]]; then
    echo "🟢 namespace=$namespace 下的 PM2 进程无 error 状态"
  else
    echo "🟢 所有 PM2 进程无 error 状态"
  fi
}

# 对外暴露的检查函数：在子 shell 中关闭 xtrace，避免打印中间变量
pm2_check_all_unerror() {
  ( set +x; _pm2_check_all_unerror_impl "$@" )
}

########################################
# 错误堆栈打印、trap 捕获等基础功能实现。
########################################
# ydyl_error.sh
# Bash-only error & stack trace module

# 防止重复 source
if [[ -n "${__YDYL_ERROR_LOADED:-}" ]]; then return 0; fi
__YDYL_ERROR_LOADED=1

# 内部状态：是否已处理过错误
__YDYL_ERR_HANDLED=0

########################################
# 打印调用栈（纯输出，无控制流）
########################################
ydyl_print_stack() {
  local code=${1:-0}
  # 优先使用传入的命令，如果没有则回退到当前 BASH_COMMAND
  local cmd="${2:-${BASH_COMMAND-}}"

  {
    echo "❌ 退出码=$code"
    if [[ -n $cmd ]]; then echo "  命令=$cmd"; fi

    local i=1
    local depth=${#FUNCNAME[@]}

    while (( i < depth )); do
      local fn="${FUNCNAME[$i]}"
      # 跳过内部框架函数
      if [[ $fn == ydyl_* ]]; then
        ((i++))
        continue
      fi

      local src="${BASH_SOURCE[$i]-unknown}"
      local lineno="${BASH_LINENO[$((i-1))]-unknown}"

      echo "  at ${src}:${lineno} ${fn}()"
      ((i++))
    done
  } >&2
}

########################################
# ERR trap：真正的错误入口
########################################
ydyl_trap_err() {
  local code=$?
  # 关键：在 trap 入口立刻捕获原始命令
  local cmd="$BASH_COMMAND"

  # 防止 ERR → exit → EXIT → 重复打印
  if (( __YDYL_ERR_HANDLED )); then
    exit "$code"
  fi

  __YDYL_ERR_HANDLED=1
  ydyl_print_stack "$code" "$cmd"
  exit "$code"
}

########################################
# EXIT trap：兜底（非 ERR 触发）
########################################
ydyl_trap_exit() {
  local code=$?
  # 关键：在 trap 入口立刻捕获原始命令
  local cmd="$BASH_COMMAND"

  # ERR 已处理过，直接返回
  if (( __YDYL_ERR_HANDLED )); then return 0; fi

  # 正常退出不打印
  [[ $code -eq 0 ]] && return 0

  __YDYL_ERR_HANDLED=1
  ydyl_print_stack "$code" "$cmd"
}

########################################
# 对外 API：启用错误处理
########################################
ydyl_enable_traps() {
  # Bash-only 保护
  if [[ -z ${BASH_VERSION:-} ]]; then
    echo "ydyl_error: requires bash" >&2
    exit 2
  fi

  trap ydyl_trap_err ERR
  trap ydyl_trap_exit EXIT
}