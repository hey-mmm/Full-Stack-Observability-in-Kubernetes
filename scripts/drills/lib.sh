#!/usr/bin/env bash
# 共享安全边界：namespace=demo、固定标签选择唯一 Deployment、有界 kubectl 调用、
# 本地 port-forward health 检查、JSONL 事件与 alert receiver 实际查询。
# 只被 scripts/drills/*.sh source，不直接执行。
set -u -o pipefail

DRILLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${DRILLS_DIR}/../.." && pwd)"

readonly NAMESPACE="demo"
readonly DEPLOYMENT_EXPECTED="demo"
readonly ARGO_NAMESPACE="${ARGO_NAMESPACE:-argocd}"
readonly ARGO_APPLICATION="demo"
readonly LABEL_SELECTOR="app.kubernetes.io/instance=demo,app.kubernetes.io/name=demo,app.kubernetes.io/component=demo-service"
readonly KUBECTL_REQUEST_TIMEOUT="${KUBECTL_REQUEST_TIMEOUT:-20s}"
readonly STATE_DIR="${DRILL_STATE_DIR:-${DRILLS_DIR}/.state}"
readonly LOG_DIR="${DRILL_LOG_DIR:-${DRILLS_DIR}/logs}"
readonly LOG_FILE="${DRILL_LOG_FILE:-${LOG_DIR}/drill-events.jsonl}"

DEPLOYMENT=""
SERVICE=""
BASE_URL=""
PF_PID=""

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'WARN: %s\n' "$*" >&2
}

utc_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

require_cmds() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "缺少命令: $cmd"
  done
}

ensure_dirs() {
  mkdir -p "$STATE_DIR" "$LOG_DIR" || die "无法创建状态/日志目录"
}

# 所有普通 kubectl 调用都带 --request-timeout；streaming 的 port-forward 单独处理。
k() {
  kubectl --request-timeout="$KUBECTL_REQUEST_TIMEOUT" "$@"
}

# JSONL 事件；值支持 __NULL__/__TRUE__/__FALSE__ 哨兵。
jsonl() {
  local file="$1"
  shift
  mkdir -p "$(dirname "$file")" || die "无法创建日志目录"
  JSONL_FILE="$file" python3 - "$@" <<'PY'
import datetime
import json
import os
import sys

record = {
    "schema_version": 1,
    "source": "scripts/drills",
    "timestamp_utc": datetime.datetime.now(datetime.timezone.utc)
    .isoformat(timespec="milliseconds")
    .replace("+00:00", "Z"),
}
for item in sys.argv[1:]:
    key, sep, value = item.partition("=")
    if not sep or not key:
        raise SystemExit(f"bad JSONL field: {item!r}")
    if value == "__NULL__":
        value = None
    elif value == "__TRUE__":
        value = True
    elif value == "__FALSE__":
        value = False
    record[key] = value

with open(os.environ["JSONL_FILE"], "a", encoding="utf-8") as fh:
    fh.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")
PY
}

select_deployment() {
  local out="" line
  local -a names=()
  if ! out="$(k -n "$NAMESPACE" get deployment -l "$LABEL_SELECTOR" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
      2>"${STATE_DIR}/last-kubectl.err")"; then
    die "无法查询 demo Deployment: $(tr '\n' ' ' < "${STATE_DIR}/last-kubectl.err" | cut -c1-300)"
  fi
  while IFS= read -r line; do
    [[ -n "$line" ]] && names+=("$line")
  done <<< "$out"
  if [[ "${#names[@]}" -ne 1 ]]; then
    die "标签 ${LABEL_SELECTOR} 在 namespace=${NAMESPACE} 匹配到 ${#names[@]} 个 Deployment；拒绝继续"
  fi
  DEPLOYMENT="${names[0]}"
  if [[ "$DEPLOYMENT" != "$DEPLOYMENT_EXPECTED" ]]; then
    die "标签选中的 Deployment 是 ${DEPLOYMENT}，预期 ${DEPLOYMENT_EXPECTED}；拒绝触碰其它应用"
  fi

  local label_instance label_name label_component actual_ns
  label_instance="$(k -n "$NAMESPACE" get deployment "$DEPLOYMENT" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/instance}')" || die "无法读取 Deployment 标签"
  label_name="$(k -n "$NAMESPACE" get deployment "$DEPLOYMENT" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/name}')" || die "无法读取 Deployment 标签"
  label_component="$(k -n "$NAMESPACE" get deployment "$DEPLOYMENT" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/component}')" || die "无法读取 Deployment 标签"
  actual_ns="$(k -n "$NAMESPACE" get deployment "$DEPLOYMENT" -o jsonpath='{.metadata.namespace}')" || die "无法读取 Deployment namespace"
  [[ "$label_instance" == "demo" ]] || die "Deployment instance 标签=${label_instance}，预期 demo"
  [[ "$label_name" == "demo" ]] || die "Deployment name 标签=${label_name}，预期 demo"
  [[ "$label_component" == "demo-service" ]] || die "Deployment component 标签=${label_component}，预期 demo-service"
  [[ "$actual_ns" == "$NAMESPACE" ]] || die "Deployment namespace=${actual_ns}，预期 ${NAMESPACE}"
}

select_service() {
  local out="" line
  local -a names=()
  if ! out="$(k -n "$NAMESPACE" get service \
      -l "app.kubernetes.io/instance=demo,app.kubernetes.io/component=demo-service" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
      2>"${STATE_DIR}/last-kubectl.err")"; then
    die "无法查询 demo Service: $(tr '\n' ' ' < "${STATE_DIR}/last-kubectl.err" | cut -c1-300)"
  fi
  while IFS= read -r line; do
    [[ -n "$line" ]] && names+=("$line")
  done <<< "$out"
  if [[ "${#names[@]}" -ne 1 ]]; then
    die "demo Service 匹配到 ${#names[@]} 个；拒绝继续"
  fi
  SERVICE="${names[0]}"
  [[ "$SERVICE" == "demo" ]] || die "Service=${SERVICE}，预期 demo；拒绝触碰其它应用"
}

start_port_forward() {
  stop_port_forward
  if [[ -n "${DEMO_BASE_URL:-}" ]]; then
    BASE_URL="${DEMO_BASE_URL%/}"
    require_cmds curl
    return 0
  fi
  require_cmds curl
  select_service
  BASE_URL="http://127.0.0.1:${DRILL_LOCAL_PORT:-18081}"
  kubectl -n "$NAMESPACE" port-forward --address 127.0.0.1 \
    "service/${SERVICE}" "${DRILL_LOCAL_PORT:-18081}:8080" \
    >"${STATE_DIR}/port-forward.log" 2>&1 &
  PF_PID=$!

  local _
  for _ in $(seq 1 40); do
    if ! kill -0 "$PF_PID" 2>/dev/null; then
      warn "port-forward 提前退出: $(tail -n 5 "${STATE_DIR}/port-forward.log" 2>/dev/null | tr '\n' ' ')"
      PF_PID=""
      return 1
    fi
    if curl -fsS --max-time 2 "${BASE_URL}/healthz" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

stop_port_forward() {
  if [[ -n "${PF_PID:-}" ]] && kill -0 "$PF_PID" 2>/dev/null; then
    kill "$PF_PID" 2>/dev/null || true
    wait "$PF_PID" 2>/dev/null || true
  fi
  PF_PID=""
}

health_ok() {
  curl -fsS --max-time 3 "${BASE_URL}/healthz" >/dev/null 2>&1 \
    && curl -fsS --max-time 3 "${BASE_URL}/readyz" >/dev/null 2>&1
}

wait_for_health() {
  local timeout="${1:-60}"
  local deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    # A Service port-forward stays attached to one Pod and exits when a
    # rollout removes it. Reconnect to the replacement before probing again.
    if [[ -z "${DEMO_BASE_URL:-}" && -n "${PF_PID:-}" ]] && ! kill -0 "$PF_PID" 2>/dev/null; then
      start_port_forward || return 1
    fi
    if health_ok; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_rollout() {
  local timeout="${1:-180}"
  timeout="${timeout%s}"
  [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=180
  local deadline=$((SECONDS + timeout))
  local spec updated ready unavailable generation observed total
  while (( SECONDS < deadline )); do
    read -r generation observed spec total updated ready unavailable < <(
      k -n "$NAMESPACE" get deployment "$DEPLOYMENT" \
        -o jsonpath='{.metadata.generation} {.status.observedGeneration} {.spec.replicas} {.status.replicas} {.status.updatedReplicas} {.status.readyReplicas} {.status.unavailableReplicas}' \
        2>/dev/null || true
    )
    [[ -n "$generation" ]] || generation=0
    [[ -n "$observed" ]] || observed=0
    [[ -n "$spec" ]] || spec=0
    [[ -n "$total" ]] || total=0
    [[ -n "$updated" ]] || updated=0
    [[ -n "$ready" ]] || ready=0
    [[ -n "$unavailable" ]] || unavailable=0
    if (( observed >= generation && generation > 0 && total == spec && updated == spec && ready >= spec && unavailable == 0 )); then
      return 0
    fi
    sleep 2
  done
  return 1
}

# 结果写入 ALERT_FIRED/ALERT_HTTP/ALERT_EVIDENCE/ALERT_QUERY。
# 未配置 URL、网络失败、响应无法判定时一律 null，不猜测。
query_alert_receiver() {
  ALERT_FIRED="__NULL__"
  ALERT_HTTP="__NULL__"
  ALERT_EVIDENCE=""
  ALERT_QUERY="__NULL__"

  if [[ -z "${ALERT_RECEIVER_URL:-}" ]]; then
    ALERT_EVIDENCE="ALERT_RECEIVER_URL 未设置；未查询 receiver API"
    return 0
  fi
  ALERT_QUERY="$ALERT_RECEIVER_URL"
  local body="${STATE_DIR}/alert-receiver-body.json"
  local err="${STATE_DIR}/alert-receiver.err"
  local code verdict
  if ! code="$(curl -sS --max-time "${ALERT_RECEIVER_TIMEOUT:-8}" \
      -o "$body" -w '%{http_code}' "$ALERT_RECEIVER_URL" 2>"$err")"; then
    ALERT_HTTP="000"
    ALERT_EVIDENCE="receiver 请求失败: $(tr '\n' ' ' < "$err" | cut -c1-300)"
    return 0
  fi
  ALERT_HTTP="$code"
  if [[ ! "$code" =~ ^2[0-9][0-9]$ ]]; then
    ALERT_EVIDENCE="receiver HTTP ${code}: $(tr '\n' ' ' < "$body" | cut -c1-300)"
    return 0
  fi

  verdict="$(python3 - "$body" "${FAULT:-}" "${STARTED_UTC:-}" <<'PY' 2>/dev/null || true
import json
import sys
from datetime import datetime

expected = {"error": "DemoHighErrorRate", "latency": "DemoP95LatencyHigh",
            "startup-failure": "DemoPodCrashLooping"}.get(sys.argv[2])
started = datetime.fromisoformat(sys.argv[3].replace("Z", "+00:00")) if sys.argv[3] else None

try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        payload = json.load(fh)
except Exception:
    print("null")
    raise SystemExit(0)

if isinstance(payload, dict) and isinstance(payload.get("data"), (dict, list)):
    payload = payload["data"]

def matches(alerts):
    found = False
    for alert in alerts:
        if not isinstance(alert, dict):
            continue
        if alert.get("status", "firing") != "firing":
            continue
        labels = alert.get("labels") or {}
        if expected and labels.get("alertname") != expected:
            continue
        if started:
            first = alert.get("startsAt")
            if not first or datetime.fromisoformat(first.replace("Z", "+00:00")) < started:
                continue
        if (
            labels.get("namespace") == "demo"
            or labels.get("deployment") == "demo"
            or labels.get("app") == "demo"
            or labels.get("service") == "demo"
        ):
            found = True
    return found

if isinstance(payload, dict):
    if isinstance(payload.get("events"), list):
        alerts = [event["alert"] for event in payload["events"]
                  if isinstance(event, dict) and isinstance(event.get("alert"), dict)]
        print("true" if matches(alerts) else "false")
    elif isinstance(payload.get("firing"), bool):
        print("true" if payload["firing"] else "false")
    elif isinstance(payload.get("alerts"), list):
        print("true" if matches(payload["alerts"]) else "false")
    else:
        print("null")
elif isinstance(payload, list):
    print("true" if matches(payload) else "false")
else:
    print("null")
PY
)"
  case "$verdict" in
    true) ALERT_FIRED="__TRUE__" ;;
    false) ALERT_FIRED="__FALSE__" ;;
    *) ALERT_FIRED="__NULL__" ;;
  esac
  ALERT_EVIDENCE="$(tr '\n' ' ' < "$body" | cut -c1-500)"
}
