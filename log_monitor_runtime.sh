#!/usr/bin/env bash
set -Eeuo pipefail

MODE=""
OUTPUT=""
ENCLAVE=""
CONTAINER=""
STACK=""

KURTOSIS_CDK_SERVICES_REGEX='^(cdk-node-|cdk-erigon-rpc-|cdk-erigon-sequencer-|zkevm-pool-manager-|zkevm-prover-|status-checker-|zkevm-bridge-service-)'
KURTOSIS_OP_SERVICES_REGEX='^(op-cl-[0-9]+-op-node-op-geth-op-kurtosis|op-el-[0-9]+-op-geth-op-node-op-kurtosis|op-batcher-op-kurtosis|op-proposer-op-kurtosis|op-challenger-op-kurtosis)$'
KURTOSIS_LOG_LEVEL_EXCLUDE_REGEX='lvl=(debug|trace)|[[:space:]](DEBUG|TRACE)[[:space:]]|\[(dbug|dbg|trace)\]'

LOG_STALL_TIMEOUT="${LOG_STALL_TIMEOUT:-120}"
WATCHDOG_INTERVAL=10
# 看门狗记录的"最后一次收到日志"的 epoch 秒，docker 模式重连时用作 --since
LAST_ACTIVITY_EPOCH=0
# 当前后台日志流的 pid（独立进程组组长），脚本退出时整组清理，避免孤儿进程
STREAM_PID=""
# Kurtosis 原始日志流活动标记文件；用于避免 DEBUG/TRACE 被过滤后误判日志流挂死
STREAM_ACTIVITY_FILE=""

usage() {
  cat <<'EOF'
用法:
  log_monitor_runtime.sh --mode kurtosis --stack cdk|op --enclave <name> --output <file>
  log_monitor_runtime.sh --mode docker --container <name> --output <file>

环境变量:
  LOG_STALL_TIMEOUT  输出文件无增长超过该秒数则判定日志流挂死并强制重连（默认 120）

示例:
  log_monitor_runtime.sh --mode kurtosis --stack cdk --enclave cdk-gen --output /home/ubuntu/ydyl-deploy-logs/a-runtime.log
  log_monitor_runtime.sh --mode docker --container testchain_node1 --output /home/ubuntu/ydyl-deploy-logs/b-runtime.log
EOF
}

kurtosis_service_name_regex() {
  local stack="${1:-$STACK}"
  case "$stack" in
    cdk)
      printf '%s\n' "$KURTOSIS_CDK_SERVICES_REGEX"
      ;;
    op)
      printf '%s\n' "$KURTOSIS_OP_SERVICES_REGEX"
      ;;
    *)
      echo "错误: 不支持的 stack=$stack" >&2
      return 1
      ;;
  esac
}

kurtosis_log_line_regex() {
  local stack="${1:-$STACK}"
  case "$stack" in
    cdk)
      printf '%s\n' '^\[(cdk-node-|cdk-erigon-rpc-|cdk-erigon-sequencer-|zkevm-pool-manager-|zkevm-prover-|status-checker-|zkevm-bridge-service-)'
      ;;
    op)
      printf '%s\n' '^\[(op-cl-[0-9]+-op-node-op-geth-op-kurtosis|op-el-[0-9]+-op-geth-op-node-op-kurtosis|op-batcher-op-kurtosis|op-proposer-op-kurtosis|op-challenger-op-kurtosis)\]'
      ;;
    *)
      echo "错误: 不支持的 stack=$stack" >&2
      return 1
      ;;
  esac
}

filter_kurtosis_log_lines() {
  local stack="${1:-$STACK}"
  local line_regex
  line_regex="$(kurtosis_log_line_regex "$stack")"
  grep --line-buffered -Ei "$line_regex" |
    grep --line-buffered -Eiv "$KURTOSIS_LOG_LEVEL_EXCLUDE_REGEX" || true
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode)
        MODE="${2:-}"
        shift 2
        ;;
      --output)
        OUTPUT="${2:-}"
        shift 2
        ;;
      --enclave)
        ENCLAVE="${2:-}"
        shift 2
        ;;
      --container)
        CONTAINER="${2:-}"
        shift 2
        ;;
      --stack)
        STACK="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "未知参数: $1" >&2
        usage
        exit 1
        ;;
    esac
  done
}

validate_args() {
  if [[ -z "$MODE" ]] || [[ -z "$OUTPUT" ]]; then
    echo "错误: --mode 与 --output 必填" >&2
    usage
    exit 1
  fi

  if [[ "$MODE" == "kurtosis" ]]; then
    if [[ -z "$ENCLAVE" ]] || [[ -z "$STACK" ]]; then
      echo "错误: kurtosis 模式下 --enclave 与 --stack 必填" >&2
      exit 1
    fi
    kurtosis_service_name_regex "$STACK" >/dev/null
  fi

  if [[ "$MODE" == "docker" ]] && [[ -z "$CONTAINER" ]]; then
    echo "错误: docker 模式下 --container 必填" >&2
    exit 1
  fi
}

cleanup_stream() {
  if [[ -n "$STREAM_PID" ]] && kill -0 "$STREAM_PID" 2>/dev/null; then
    kill -- "-$STREAM_PID" 2>/dev/null || kill "$STREAM_PID" 2>/dev/null || true
  fi
}

cleanup_all() {
  cleanup_stream
  if [[ -n "$STREAM_ACTIVITY_FILE" ]]; then
    rm -f "$STREAM_ACTIVITY_FILE"
  fi
}

output_size() {
  stat -c %s "$OUTPUT" 2>/dev/null || stat -f %z "$OUTPUT" 2>/dev/null || echo 0
}

activity_marker() {
  if [[ -n "$STREAM_ACTIVITY_FILE" ]] && [[ -f "$STREAM_ACTIVITY_FILE" ]]; then
    stat -c %Y "$STREAM_ACTIVITY_FILE" 2>/dev/null || stat -f %m "$STREAM_ACTIVITY_FILE" 2>/dev/null || echo 0
  else
    output_size
  fi
}

reset_stream_activity() {
  if [[ -n "$STREAM_ACTIVITY_FILE" ]]; then
    : >"$STREAM_ACTIVITY_FILE"
  fi
}

mark_stream_activity() {
  local line
  while IFS= read -r line; do
    if [[ -n "$STREAM_ACTIVITY_FILE" ]]; then
      : >"$STREAM_ACTIVITY_FILE"
    fi
    printf '%s\n' "$line"
  done
}

# 后台运行给定的日志流命令，监控输出文件大小或原始流活动；
# 超过 LOG_STALL_TIMEOUT 秒无活动则 kill 整个进程组并返回，由调用方重连。
run_stream_with_watchdog() {
  local cur_marker last_marker now

  reset_stream_activity
  "$@" &
  STREAM_PID=$!
  last_marker="$(activity_marker)"
  LAST_ACTIVITY_EPOCH="$(date +%s)"

  while kill -0 "$STREAM_PID" 2>/dev/null; do
    sleep "$WATCHDOG_INTERVAL"
    cur_marker="$(activity_marker)"
    now="$(date +%s)"
    if [[ "$cur_marker" != "$last_marker" ]]; then
      last_marker="$cur_marker"
      LAST_ACTIVITY_EPOCH="$now"
    elif (( now - LAST_ACTIVITY_EPOCH >= LOG_STALL_TIMEOUT )); then
      echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] 输出 ${LOG_STALL_TIMEOUT}s 无活动，判定日志流挂死，强制重连"
      cleanup_stream
      break
    fi
  done
  wait "$STREAM_PID" 2>/dev/null || true
  STREAM_PID=""
}

wait_for_enclave() {
  local enclave="$1"
  local max_rounds=180
  local round=1
  while (( round <= max_rounds )); do
    if kurtosis enclave inspect "$enclave" >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
    round=$((round + 1))
  done
  return 1
}

list_kurtosis_services() {
  local enclave="$1"
  local stack="$2"
  local service_regex
  service_regex="$(kurtosis_service_name_regex "$stack")"
  kurtosis enclave inspect "$enclave" |
    awk '
      /^=+ User Services =+/ {in_user=1; next}
      /^=+/ {if (in_user) exit}
      in_user && /^[0-9a-f]{12,}[[:space:]]+/ {print $2}
    ' |
    grep -Ei "$service_regex" || true
}

wait_for_kurtosis_services() {
  local enclave="$1"
  local stack="$2"
  local max_rounds=360
  local round=1
  local services_output=""

  while (( round <= max_rounds )); do
    services_output="$(list_kurtosis_services "$enclave" "$stack")"
    if [[ -n "$services_output" ]]; then
      printf '%s\n' "$services_output"
      return 0
    fi
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] enclave 已就绪但主要服务尚未出现，继续等待: $enclave (${round}/${max_rounds})"
    sleep 5
    round=$((round + 1))
  done

  return 1
}

wait_for_container() {
  local container="$1"
  local max_rounds=180
  local round=1
  while (( round <= max_rounds )); do
    if docker ps -a --format '{{.Names}}' | grep -Fxq "$container"; then
      return 0
    fi
    sleep 5
    round=$((round + 1))
  done
  return 1
}

run_kurtosis_monitor() {
  local enclave="$1"
  local stack="$2"
  local services_output=""
  local services=()

  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] 等待 kurtosis enclave 就绪: $enclave"
  if ! wait_for_enclave "$enclave"; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] enclave 等待超时: $enclave"
    exit 1
  fi
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] enclave 已可访问，等待主要服务就绪: $enclave"
  while true; do
    if services_output="$(wait_for_kurtosis_services "$enclave" "$stack")"; then
      mapfile -t services <<<"$services_output"
      break
    fi
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] 主要服务等待超时，继续重试: $enclave"
    sleep 5
  done

  if [[ "${#services[@]}" -eq 0 ]]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] 未发现可跟踪的主要服务: $enclave"
    exit 1
  fi

  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] 开始跟踪服务日志(全量历史 -a + 白名单/级别过滤): ${services[*]}"
  run_stream_with_watchdog stream_kurtosis_logs "$enclave" "$stack" -a
  while true; do
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] 日志流退出，5秒后重连(仅新增 -n 0): $enclave"
    sleep 5
    run_stream_with_watchdog stream_kurtosis_logs "$enclave" "$stack" -n 0
  done
}

# 用法: stream_kurtosis_logs <enclave> <stack> [额外 kurtosis flags...]
stream_kurtosis_logs() {
  local enclave="$1"
  local stack="$2"
  shift 2
  kurtosis service logs -f "$@" "$enclave" 2>&1 |
    mark_stream_activity |
    filter_kurtosis_log_lines "$stack"
}

run_docker_monitor() {
  local container="$1"
  local since=""
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] 等待 docker 容器就绪: $container"
  if ! wait_for_container "$container"; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] 容器等待超时: $container"
    exit 1
  fi

  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] 开始跟踪容器日志: $container"
  run_stream_with_watchdog stream_docker_logs "$container"
  while true; do
    # 用最后一次收到日志的时间点衔接，避免重连后重放全量历史
    since="$LAST_ACTIVITY_EPOCH"
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] 容器日志流退出，5秒后重连(--since $since): $container"
    sleep 5
    run_stream_with_watchdog stream_docker_logs "$container" --since "$since"
  done
}

# 用法: stream_docker_logs <container> [额外 docker logs flags...]
stream_docker_logs() {
  local container="$1"
  shift
  docker logs -f "$@" "$container" 2>&1 | sed -u "s/^/[$container] /"
}

main() {
  parse_args "$@"
  validate_args

  mkdir -p "$(dirname "$OUTPUT")"
  exec >>"$OUTPUT" 2>&1

  # 启用 job control，使后台日志流管道拥有独立进程组，便于看门狗整组 kill
  set -m

  if [[ "$MODE" == "kurtosis" ]]; then
    STREAM_ACTIVITY_FILE="$(mktemp "${TMPDIR:-/tmp}/ydyl-log-monitor-activity.XXXXXX")"
  fi

  trap cleanup_all EXIT
  trap 'cleanup_all; exit 143' INT TERM

  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] 启动运行日志监控: mode=$MODE"
  case "$MODE" in
    kurtosis)
      run_kurtosis_monitor "$ENCLAVE" "$STACK"
      ;;
    docker)
      run_docker_monitor "$CONTAINER"
      ;;
    *)
      echo "错误: 不支持的 mode=$MODE" >&2
      exit 1
      ;;
  esac
}

if [[ "${YDYL_LOG_MONITOR_SOURCE_ONLY:-}" != "1" ]]; then
  main "$@"
fi
