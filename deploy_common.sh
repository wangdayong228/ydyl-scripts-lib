#!/usr/bin/env bash

# ydyl_kurtosis_deploy
#
# 通过 DEPLOY_* 环境变量执行通用 kurtosis 部署流程（方案B：避免长参数列表）。
# 命名统一使用 "-"：
# - ENCLAVE_NAME="${DEPLOY_L2_TYPE}-${DEPLOY_NETWORK}"
# - params/log/result 文件名也建议使用同一风格（由调用方传入路径）
#
# 必需环境变量：
# - DEPLOY_L2_TYPE              cdk/op
# - DEPLOY_NETWORK              eth/cfx-dev/cfx-test/gen ...
# - DEPLOY_TEMPLATE_FILE        模板路径
# - DEPLOY_RENDERED_ARGS_FILE   渲染后的 args 文件路径
# - DEPLOY_LOG_FILE             日志文件路径
# - DEPLOY_PACKAGE_LOCATOR      kurtosis package locator
#
# 可选环境变量：
# - DEPLOY_UPDATE_NGINX_SCRIPT  nginx 更新脚本路径（必填）
# - DEPLOY_DRYRUN               true/false（默认 false）
# - DEPLOY_FORCE                true/false（默认 false）
#
# 输出（export）：
# - YDYL_DEPLOY_ENCLAVE_NAME
# - YDYL_DEPLOY_STATUS          dryrun/ran/skipped


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/utils.sh"

ydyl_kurtosis_deploy() {
  if [ -z "${DEPLOY_L2_TYPE:-}" ]; then echo "缺少 DEPLOY_L2_TYPE" >&2; return 1; fi
  if [ -z "${DEPLOY_NETWORK:-}" ]; then echo "缺少 DEPLOY_NETWORK" >&2; return 1; fi
  if [ -z "${DEPLOY_TEMPLATE_FILE:-}" ]; then echo "缺少 DEPLOY_TEMPLATE_FILE" >&2; return 1; fi
  if [ -z "${DEPLOY_RENDERED_ARGS_FILE:-}" ]; then echo "缺少 DEPLOY_RENDERED_ARGS_FILE" >&2; return 1; fi
  if [ -z "${DEPLOY_LOG_FILE:-}" ]; then echo "缺少 DEPLOY_LOG_FILE" >&2; return 1; fi
  if [ -z "${DEPLOY_PACKAGE_LOCATOR:-}" ]; then echo "缺少 DEPLOY_PACKAGE_LOCATOR" >&2; return 1; fi
  if [ -z "${DEPLOY_UPDATE_NGINX_SCRIPT:-}" ]; then echo "缺少 DEPLOY_UPDATE_NGINX_SCRIPT" >&2; return 1; fi

  local dryrun="${DEPLOY_DRYRUN:-false}"
  local force="${DEPLOY_FORCE:-false}"

  local enclave_name="${DEPLOY_L2_TYPE}-${DEPLOY_NETWORK}"
  export YDYL_DEPLOY_ENCLAVE_NAME="$enclave_name"
  export YDYL_DEPLOY_STATUS="skipped"

  require_command kurtosis || return 1
  require_command envsubst || return 1

  mkdir -p "$(dirname "$DEPLOY_RENDERED_ARGS_FILE")" || return 1
  mkdir -p "$(dirname "$DEPLOY_LOG_FILE")" || return 1

  local need_deploy="false"
  if [ "$dryrun" == "true" ]; then
    echo "DRYRUN 模式: $dryrun"
    echo "DRYRUN 模式下，不执行实际部署，只打印部署命令和检查参数是否正确"
  elif [ "$force" == "true" ]; then
    echo "FORCE 模式: $force"
    echo "FORCE 模式下，且非 DRYRUN 模式下，无论 enclave 是否存在，都强制部署"
    need_deploy="true"
  else
    echo "普通部署模式: DRYRUN=false, FORCE=false"
    echo "普通部署模式下，如果 enclave 已经存在，可以选择不重新部署"
    if kurtosis enclave ls | grep -q "$enclave_name"; then
      echo "检测到已存在的 enclave: $enclave_name，跳过部署"
      need_deploy="false"
    else
      echo "未检测到已有 enclave: $enclave_name，将进行部署"
      need_deploy="true"
    fi
  fi

  if [ "$dryrun" == "true" ]; then
    echo "[dry-run] envsubst < $DEPLOY_TEMPLATE_FILE > $DEPLOY_RENDERED_ARGS_FILE"
    echo "[dry-run] kurtosis run --cli-log-level debug -v EXECUTABLE --enclave $enclave_name --args-file $DEPLOY_RENDERED_ARGS_FILE $DEPLOY_PACKAGE_LOCATOR > $DEPLOY_LOG_FILE 2>&1"
    echo "[dry-run] set nginx for $enclave_name"
    export YDYL_DEPLOY_STATUS="dryrun"
    return 0
  fi

  if [ "$need_deploy" == "true" ]; then
    if kurtosis enclave ls | grep -q "$enclave_name"; then
      kurtosis enclave rm -f "$enclave_name"
      echo "删除旧的 enclave $enclave_name"
    fi

    envsubst < "$DEPLOY_TEMPLATE_FILE" > "$DEPLOY_RENDERED_ARGS_FILE" || return 1
    check_template_substitution "$DEPLOY_RENDERED_ARGS_FILE" || return 1
    echo "generated args file: $DEPLOY_RENDERED_ARGS_FILE"

    echo "running kurtosis run with retry 10 times, 5 seconds interval"
    run_with_retry 10 5 kurtosis run --cli-log-level debug -v EXECUTABLE --enclave "$enclave_name" --args-file "$DEPLOY_RENDERED_ARGS_FILE" "$DEPLOY_PACKAGE_LOCATOR" >"$DEPLOY_LOG_FILE" 2>&1 || return 1
    echo "kurtosis run with retry completed"

    export YDYL_DEPLOY_STATUS="ran"
  else
    export YDYL_DEPLOY_STATUS="skipped"
    echo "skip deployment kurtosis enclave: $enclave_name"
  fi

  bash "$DEPLOY_UPDATE_NGINX_SCRIPT" "$enclave_name" || return 1
  echo "set nginx for $enclave_name"
}


