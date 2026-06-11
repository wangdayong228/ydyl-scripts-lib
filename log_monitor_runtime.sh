#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
用法:
  log_monitor_runtime.sh --mode kurtosis|docker --output <file> [--enclave <name>] [--container <name>]

环境变量:
  LOG_STALL_TIMEOUT  输出文件无增长超过该秒数则判定日志流挂死并强制重连（默认 120）

示例:
  log_monitor_runtime.sh --mode kurtosis --enclave cdk-gen --output /home/ubuntu/ydyl-deploy-logs/a-runtime.log
  log_monitor_runtime.sh --mode docker --container testchain_node1 --output /home/ubuntu/ydyl-deploy-logs/b-runtime.log
EOF
}

MODE=""
OUTPUT=""
ENCLAVE=""
CONTAINER=""

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

if [[ -z "$MODE" ]] || [[ -z "$OUTPUT" ]]; then
  echo "错误: --mode 与 --output 必填" >&2
  usage
  exit 1
fi

if [[ "$MODE" == "kurtosis" ]] && [[ -z "$ENCLAVE" ]]; then
  echo "错误: kurtosis 模式下 --enclave 必填" >&2
  exit 1
fi

if [[ "$MODE" == "docker" ]] && [[ -z "$CONTAINER" ]]; then
  echo "错误: docker 模式下 --container 必填" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"
exec >>"$OUTPUT" 2>&1

# 启用 job control，使后台日志流管道拥有独立进程组，便于看门狗整组 kill
set -m

KURTOSIS_EXCLUDE_SERVICES_REGEX='grafana|prometheus|blockscout'
LOG_STALL_TIMEOUT="${LOG_STALL_TIMEOUT:-120}"
WATCHDOG_INTERVAL=10
# 看门狗记录的"最后一次收到日志"的 epoch 秒，docker 模式重连时用作 --since
LAST_ACTIVITY_EPOCH=0
# 当前后台日志流的 pid（独立进程组组长），脚本退出时整组清理，避免孤儿进程
STREAM_PID=""

cleanup_stream() {
  if [[ -n "$STREAM_PID" ]] && kill -0 "$STREAM_PID" 2>/dev/null; then
    kill -- "-$STREAM_PID" 2>/dev/null || kill "$STREAM_PID" 2>/dev/null || true
  fi
}
trap cleanup_stream EXIT
trap 'cleanup_stream; exit 143' INT TERM

output_size() {
  stat -c %s "$OUTPUT" 2>/dev/null || stat -f %z "$OUTPUT" 2>/dev/null || echo 0
}

# 后台运行给定的日志流命令，监控输出文件大小；
# 超过 LOG_STALL_TIMEOUT 秒无增长则 kill 整个进程组并返回，由调用方重连。
run_stream_with_watchdog() {
  local cur_size last_size now

  "$@" &
  STREAM_PID=$!
  last_size="$(output_size)"
  LAST_ACTIVITY_EPOCH="$(date +%s)"

  while kill -0 "$STREAM_PID" 2>/dev/null; do
    sleep "$WATCHDOG_INTERVAL"
    cur_size="$(output_size)"
    now="$(date +%s)"
    if [[ "$cur_size" != "$last_size" ]]; then
      last_size="$cur_size"
      LAST_ACTIVITY_EPOCH="$now"
    elif (( now - LAST_ACTIVITY_EPOCH >= LOG_STALL_TIMEOUT )); then
      echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] 输出 ${LOG_STALL_TIMEOUT}s 无增长，判定日志流挂死，强制重连"
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
  kurtosis enclave inspect "$enclave" |
    awk '
      /^=+ User Services =+/ {in_user=1; next}
      /^=+/ {if (in_user) exit}
      in_user && /^[0-9a-f]{12,}[[:space:]]+/ {print $2}
    ' |
    grep -Eiv "$KURTOSIS_EXCLUDE_SERVICES_REGEX" || true
}

wait_for_kurtosis_services() {
  local enclave="$1"
  local max_rounds=360
  local round=1
  local services_output=""

  while (( round <= max_rounds )); do
    services_output="$(list_kurtosis_services "$enclave")"
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
  local services_output=""
  local services=()

  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] 等待 kurtosis enclave 就绪: $enclave"
  if ! wait_for_enclave "$enclave"; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] enclave 等待超时: $enclave"
    exit 1
  fi
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] enclave 已可访问，等待主要服务就绪: $enclave"
  while true; do
    if services_output="$(wait_for_kurtosis_services "$enclave")"; then
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

  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] 开始跟踪服务日志(全量历史 -a + grep过滤): ${services[*]}"
  run_stream_with_watchdog stream_kurtosis_logs "$enclave" -a
  while true; do
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] 日志流退出，5秒后重连(仅新增 -n 0): $enclave"
    sleep 5
    run_stream_with_watchdog stream_kurtosis_logs "$enclave" -n 0
  done
}

# 用法: stream_kurtosis_logs <enclave> [额外 kurtosis flags...]
stream_kurtosis_logs() {
  local enclave="$1"
  shift
  kurtosis service logs -f "$@" "$enclave" 2>&1 |
    grep --line-buffered -Eiv "$KURTOSIS_EXCLUDE_SERVICES_REGEX"
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

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] 启动运行日志监控: mode=$MODE"
case "$MODE" in
  kurtosis)
    run_kurtosis_monitor "$ENCLAVE"
    ;;
  docker)
    run_docker_monitor "$CONTAINER"
    ;;
  *)
    echo "错误: 不支持的 mode=$MODE" >&2
    exit 1
    ;;
esac
