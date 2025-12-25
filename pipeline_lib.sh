#!/bin/bash
# 通用流水线工具函数库，可在多个 *pipe.sh 中复用

# 加载状态文件，初始化 LAST_DONE_STEP（默认 0）
pipeline_load_state() {
  LAST_DONE_STEP=0
  if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  fi
}

# 保存当前步骤及持久化变量到状态文件
save_state() {
  local step="$1"
  # DRYRUN=false（或未显式设为 true）时，不进行状态持久化
  if [ "${DRYRUN:-false}" = "true" ]; then
    echo "ℹ️ DRYRUN=true，跳过状态持久化（环境变量与步骤进度不会保存）"
    return 0
  fi
  {
    echo "LAST_DONE_STEP=$step"
    for v in "${PERSIST_VARS[@]}"; do
      if [ -n "${!v-}" ]; then
        printf '%s=%q\n' "$v" "${!v}"
      fi
    done
  } >"$STATE_FILE"
  echo "✅ 状态已保存到 $STATE_FILE (LAST_DONE_STEP=$step)"
}

# 检查关键输入环境变量是否与历史状态一致
check_input_env_compat() {
  local name="$1"
  local orig_name="ORIG_${name}"
  local orig_val="${!orig_name-}"
  local persisted_val="${!name-}"

  # 如果本次有显式传入，且状态文件中也有对应值但不同，则报错
  if [ -n "$orig_val" ] && [ -n "$persisted_val" ] && [ "$orig_val" != "$persisted_val" ]; then
    echo "错误: 当前环境变量 $name=$orig_val 与状态文件中保存的值 $name=$persisted_val 不一致。"
    echo "为避免混用不同配置，请先删除状态文件后再重新执行："
    echo "  rm \"$STATE_FILE\" && ./cdk_pipe.sh"
    exit 1
  fi

  # 如果状态文件中没有该变量，但本次有传入，则以后以本次传入为准
  if [ -n "$orig_val" ] && [ -z "$persisted_val" ]; then
    printf -v "$name" '%s' "$orig_val"
    # export 动态变量名（如 L1_CHAIN_ID）；使用 ${name?} 明确告诉 shellcheck 这是变量名而非字面量 "name"
    export "${name?}"
  fi
}

# 解析 START_STEP（优先环境变量，其次第一个参数），默认从上次完成步骤的下一步开始
pipeline_parse_start_step() {
  START_STEP="${START_STEP:-}"
  if [ -z "$START_STEP" ] && [ $# -ge 1 ]; then
    START_STEP="$1"
  fi
  if [ -z "$START_STEP" ]; then
    # LAST_DONE_STEP 可能尚未初始化，这里使用默认 0，避免 set -u 报错
    local last="${LAST_DONE_STEP:-0}"
    START_STEP=$((last + 1))
  fi

  echo "当前记录已完成到步骤: ${LAST_DONE_STEP:-0}，本次从步骤: $START_STEP 开始执行"
}

# 通用步骤执行器
run_step() {
  local step="$1"
  local name="$2"
  shift 2
  if [ "$step" -lt "$START_STEP" ]; then
    echo "⏭️ 跳过 STEP$step: $name (因为 START_STEP=$START_STEP)"
    return 0
  fi

  echo "🔹 开始 STEP$step: $name"
  "$@"
  save_state "$step"
  echo "✅ 完成 STEP$step: $name"
}


