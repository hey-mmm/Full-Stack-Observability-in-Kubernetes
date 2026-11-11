#!/usr/bin/env bash
# 对 demo 服务持续/限量发送 /work 正常请求，仅使用 curl。
# 不执行 kubectl，不修改 Deployment/env/资源；故障演练请通过 Helm values 的 env + rollout 完成。
set -u -o pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"
RATE="${RATE:-2}"                 # 每秒请求数；0 表示不限速
DURATION="${DURATION:-0}"         # 运行秒数；0 表示不按时间退出
REQUESTS="${REQUESTS:-0}"         # 最大请求数；0 表示不按数量退出
TIMEOUT="${TIMEOUT:-5}"           # 单请求 curl 超时秒数
LOG_FILE="${LOG_FILE:-}"
ALLOW_ERRORS="${ALLOW_ERRORS:-0}"

usage() {
  cat <<'EOF'
用法: scripts/traffic.sh [选项]

选项:
  --base-url URL    服务根地址（默认 $BASE_URL 或 http://127.0.0.1:8080）
  --rate N          每秒请求数，0 为不限速（默认 2）
  --duration SEC    运行 SEC 秒后退出，0 为不限时（默认 0）
  --requests N      最多发送 N 个请求后退出，0 为不限量（默认 0）
  --timeout SEC     单请求超时（默认 5）
  --log-file PATH   同时追加请求日志到文件（默认只输出 stdout）
  --allow-errors    HTTP 非 2xx 或传输错误也不以非 0 退出（用于故障演练）
  -h, --help        显示本帮助

示例:
  scripts/traffic.sh --base-url http://127.0.0.1:18080 --rate 5 --duration 60
  scripts/traffic.sh --requests 100 --rate 0
  BASE_URL=http://127.0.0.1:18080 scripts/traffic.sh --duration 30 --log-file /tmp/traffic.log
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-url) BASE_URL="${2:?--base-url 需要参数}"; shift 2 ;;
    --rate) RATE="${2:?--rate 需要参数}"; shift 2 ;;
    --duration) DURATION="${2:?--duration 需要参数}"; shift 2 ;;
    --requests) REQUESTS="${2:?--requests 需要参数}"; shift 2 ;;
    --timeout) TIMEOUT="${2:?--timeout 需要参数}"; shift 2 ;;
    --log-file) LOG_FILE="${2:?--log-file 需要参数}"; shift 2 ;;
    --allow-errors) ALLOW_ERRORS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v curl >/dev/null 2>&1 || { echo "错误: 需要 curl" >&2; exit 2; }
[[ -n "$BASE_URL" ]] || { echo "错误: BASE_URL 不能为空" >&2; exit 2; }
[[ "$RATE" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "错误: --rate 必须 >= 0" >&2; exit 2; }
[[ "$DURATION" =~ ^[0-9]+$ ]] || { echo "错误: --duration 必须是非负整数" >&2; exit 2; }
[[ "$REQUESTS" =~ ^[0-9]+$ ]] || { echo "错误: --requests 必须是非负整数" >&2; exit 2; }
[[ "$TIMEOUT" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "错误: --timeout 必须是正数" >&2; exit 2; }
awk -v t="$TIMEOUT" 'BEGIN { exit !(t > 0) }' || { echo "错误: --timeout 必须大于 0" >&2; exit 2; }
[[ "$ALLOW_ERRORS" == "0" || "$ALLOW_ERRORS" == "1" ]] || { echo "错误: ALLOW_ERRORS 只能为 0/1" >&2; exit 2; }
if [[ "$DURATION" == "0" && "$REQUESTS" == "0" ]]; then
  echo "提示: 未设置 --duration/--requests，将持续运行直到 Ctrl-C。" >&2
fi

URL="${BASE_URL%/}"
[[ "$URL" == */work ]] || URL="$URL/work"

if awk -v r="$RATE" 'BEGIN { exit !(r > 0) }'; then
  INTERVAL="$(awk -v r="$RATE" 'BEGIN { printf "%.3f", 1 / r }')"
else
  INTERVAL="0"
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/demo-traffic.XXXXXX")" || exit 2
BODY_FILE="$WORKDIR/body"
ERR_FILE="$WORKDIR/err"
trap 'rm -rf "$WORKDIR"' EXIT

STOP=0
INTERRUPTED=0
trap 'STOP=1; INTERRUPTED=1' INT TERM

COUNT=0
OK=0
HTTP_FAIL=0
TRANSPORT_FAIL=0
START_EPOCH="$(date +%s)"

log_line() {
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local line
  line="$ts status=$STATUS duration_seconds=$DURATION_SEC request_id=$REQUEST_ID request=$COUNT url=$URL"
  if [[ -n "$RESPONSE_NOTE" ]]; then
    line="$line note=$RESPONSE_NOTE"
  fi
  if [[ -n "$LOG_FILE" ]]; then
    printf '%s\n' "$line" >> "$LOG_FILE"
  else
    printf '%s\n' "$line"
  fi
}

while [[ "$STOP" -eq 0 ]]; do
  if [[ "$REQUESTS" -gt 0 && "$COUNT" -ge "$REQUESTS" ]]; then
    break
  fi
  if [[ "$DURATION" -gt 0 ]]; then
    ELAPSED=$(( $(date +%s) - START_EPOCH ))
    if [[ "$ELAPSED" -ge "$DURATION" ]]; then
      break
    fi
  fi

  COUNT=$((COUNT + 1))
  REQUEST_ID="traffic-$$-$COUNT"
  STATUS="000"
  DURATION_SEC="0"
  RESPONSE_NOTE=""
  RAW=""

  if RAW="$(curl -sS --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" \
      -H "X-Request-ID: $REQUEST_ID" \
      -o "$BODY_FILE" -w '%{http_code} %{time_total}' "$URL" 2>"$ERR_FILE")"; then
    read -r STATUS DURATION_SEC <<< "$RAW" || true
  else
    STATUS="000"
    DURATION_SEC="0"
    TRANSPORT_FAIL=$((TRANSPORT_FAIL + 1))
    RESPONSE_NOTE="transport_error:$(tr '\n' ' ' < "$ERR_FILE" | cut -c1-200)"
  fi

  if [[ "$STATUS" =~ ^2[0-9][0-9]$ ]]; then
    OK=$((OK + 1))
  elif [[ "$STATUS" != "000" ]]; then
    HTTP_FAIL=$((HTTP_FAIL + 1))
    RESPONSE_NOTE="http_$(tr '\n' ' ' < "$BODY_FILE" | cut -c1-200)"
  fi

  log_line

  if [[ "$INTERVAL" != "0" && "$STOP" -eq 0 ]]; then
    SLEEP_FOR="$(awk -v i="$INTERVAL" -v d="$DURATION_SEC" 'BEGIN { s = i - d; if (s < 0) s = 0; printf "%.3f", s }')"
    [[ "$SLEEP_FOR" == "0.000" ]] || sleep "$SLEEP_FOR"
  fi
done

TOTAL_SECONDS=$(( $(date +%s) - START_EPOCH ))
echo "traffic summary: requests=$COUNT ok=$OK http_fail=$HTTP_FAIL transport_fail=$TRANSPORT_FAIL seconds=$TOTAL_SECONDS target=$URL" >&2

if [[ "$INTERRUPTED" -eq 1 ]]; then
  exit 130
fi
if [[ "$TRANSPORT_FAIL" -gt 0 || "$HTTP_FAIL" -gt 0 ]]; then
  if [[ "$ALLOW_ERRORS" -eq 1 ]]; then
    exit 0
  fi
  exit 1
fi
exit 0
