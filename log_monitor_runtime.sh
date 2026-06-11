#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
用法:
  log_monitor_runtime.sh --mode kurtosis|docker --output <file> [--enclave <name>] [--container <name>]

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

KURTOSIS_EXCLUDE_SERVICES_REGEX='grafana|prometheus|blockscout'

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

  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] 开始跟踪服务日志(-a + grep过滤): ${services[*]}"
  while true; do
    if kurtosis service logs -f -a "$enclave" 2>&1 | grep -Eiv "$KURTOSIS_EXCLUDE_SERVICES_REGEX"; then
      echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] 日志流已结束，5秒后重连: $enclave"
    else
      echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] 日志流异常退出，5秒后重连: $enclave"
    fi
    sleep 5
  done
}

run_docker_monitor() {
  local container="$1"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] 等待 docker 容器就绪: $container"
  if ! wait_for_container "$container"; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] 容器等待超时: $container"
    exit 1
  fi

  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] 开始跟踪容器日志: $container"
  docker logs -f "$container" 2>&1 | sed "s/^/[$container] /"
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
