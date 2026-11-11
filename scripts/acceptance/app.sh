#!/usr/bin/env bash
# 验收 demo 服务：检查 /healthz、/readyz、/metrics、/version、/work 的 JSON 与 request_id。
# 默认用 kubectl 按 release 标签找到 Service 并建立本脚本自己的 port-forward；也支持 BASE_URL。
# 只做只读查询与本地转发，不修改集群资源。任何检查失败返回非 0，并清理本脚本的转发进程。
set -u -o pipefail

RELEASE="${RELEASE:-demo}"
NAMESPACE="${NAMESPACE:-default}"
BASE_URL="${BASE_URL:-}"
SERVICE="${SERVICE:-}"
LOCAL_PORT="${LOCAL_PORT:-18080}"
TIMEOUT="${TIMEOUT:-10}"
EXPECT_VERSION="${EXPECT_VERSION:-}"
EXPECT_GIT_SHA="${EXPECT_GIT_SHA:-}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
KUBECTL=(kubectl)

usage() {
  cat <<'EOF'
用法: scripts/acceptance/app.sh [选项]

选项:
  --release NAME        Helm release 名（默认 demo；按 app.kubernetes.io/instance 标签找 Service）
  --namespace NS        namespace（默认 default）
  --service NAME        直接指定 Service，跳过按 release 标签查找
  --base-url URL        直接检查该地址，不执行 kubectl/port-forward
  --local-port PORT     port-forward 本地端口（默认 18080）
  --timeout SEC         单请求超时（默认 10）
  --expect-version V    断言 /version 的 app_version
  --expect-git-sha S    断言 /version 的 git_sha
  --context NAME        kubectl context
  --kubeconfig PATH     kubectl kubeconfig
  -h, --help            显示本帮助

示例:
  scripts/acceptance/app.sh --release demo --namespace observability
  scripts/acceptance/app.sh --base-url http://127.0.0.1:18080 --expect-version 0.1.0 --expect-git-sha abc1234
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) RELEASE="${2:?--release 需要参数}"; shift 2 ;;
    --namespace) NAMESPACE="${2:?--namespace 需要参数}"; shift 2 ;;
    --service) SERVICE="${2:?--service 需要参数}"; shift 2 ;;
    --base-url) BASE_URL="${2:?--base-url 需要参数}"; shift 2 ;;
    --local-port) LOCAL_PORT="${2:?--local-port 需要参数}"; shift 2 ;;
    --timeout) TIMEOUT="${2:?--timeout 需要参数}"; shift 2 ;;
    --expect-version) EXPECT_VERSION="${2:?--expect-version 需要参数}"; shift 2 ;;
    --expect-git-sha) EXPECT_GIT_SHA="${2:?--expect-git-sha 需要参数}"; shift 2 ;;
    --context) KUBECTL+=(--context "${2:?--context 需要参数}"); shift 2 ;;
    --kubeconfig) KUBECTL+=(--kubeconfig "${2:?--kubeconfig 需要参数}"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v curl >/dev/null 2>&1 || { echo "错误: 需要 curl" >&2; exit 2; }
command -v "$PYTHON_BIN" >/dev/null 2>&1 || { echo "错误: 需要 $PYTHON_BIN 解析 JSON" >&2; exit 2; }
if [[ -z "$BASE_URL" ]]; then
  command -v kubectl >/dev/null 2>&1 || { echo "错误: 需要 kubectl 或 --base-url" >&2; exit 2; }
  "${KUBECTL[@]}" version --client >/dev/null 2>&1 || { echo "错误: kubectl 不可用" >&2; exit 2; }
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/demo-acceptance.XXXXXX")" || exit 2
PF_PID=""
FAILURES=0
CHECKS=0

cleanup() {
  if [[ -n "${PF_PID:-}" ]] && kill -0 "$PF_PID" 2>/dev/null; then
    kill "$PF_PID" 2>/dev/null || true
    wait "$PF_PID" 2>/dev/null || true
  fi
  rm -rf "$WORKDIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

pass_check() {
  CHECKS=$((CHECKS + 1))
  printf 'PASS %s\n' "$*"
}

fail_check() {
  CHECKS=$((CHECKS + 1))
  FAILURES=$((FAILURES + 1))
  printf 'FAIL %s\n' "$*" >&2
}

finish() {
  echo "acceptance summary: checks=$CHECKS failures=$FAILURES target=$BASE_URL" >&2
  if [[ "$FAILURES" -gt 0 ]]; then
    exit 1
  fi
  exit 0
}

http_get() {
  local url="$1" body="$2" headers="$3" request_id="${4:-}"
  local -a curl_args=(-sS --max-time "$TIMEOUT" -D "$headers" -o "$body" -w '%{http_code}')
  if [[ -n "$request_id" ]]; then
    curl_args+=(-H "X-Request-ID: $request_id")
  fi
  local code
  if code="$(curl "${curl_args[@]}" "$url" 2>"$WORKDIR/curl.err")"; then
    printf '%s' "$code"
  else
    printf '000'
  fi
}

start_port_forward() {
  BASE_URL="${BASE_URL%/}"

  if [[ -z "$SERVICE" ]]; then
    local services_out
    if ! services_out="$("${KUBECTL[@]}" -n "$NAMESPACE" get svc \
        -l "app.kubernetes.io/instance=${RELEASE},app.kubernetes.io/component=demo-service" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>"$WORKDIR/kubectl.err")"; then
      echo "错误: 无法按 release=${RELEASE} 查询 Service" >&2
      cat "$WORKDIR/kubectl.err" >&2
      exit 1
    fi
    local found=()
    mapfile -t found < <(printf '%s\n' "$services_out" | sed '/^[[:space:]]*$/d')
    if [[ "${#found[@]}" -ne 1 ]]; then
      echo "错误: release=${RELEASE} 在 namespace=${NAMESPACE} 匹配到 ${#found[@]} 个 Service，请用 --service 指定。" >&2
      exit 1
    fi
    SERVICE="${found[0]}"
  fi

  local svc_port
  svc_port="$("${KUBECTL[@]}" -n "$NAMESPACE" get svc "$SERVICE" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || true)"
  [[ -n "$svc_port" ]] || svc_port="8080"
  BASE_URL="http://127.0.0.1:${LOCAL_PORT}"

  echo "使用 kubectl port-forward: namespace=$NAMESPACE service=$SERVICE ${LOCAL_PORT}:${svc_port}" >&2
  "${KUBECTL[@]}" -n "$NAMESPACE" port-forward --address 127.0.0.1 "svc/$SERVICE" "${LOCAL_PORT}:${svc_port}" \
    >"$WORKDIR/port-forward.log" 2>&1 &
  PF_PID=$!

  local ready=0
  for _ in $(seq 1 60); do
    if ! kill -0 "$PF_PID" 2>/dev/null; then
      break
    fi
    if curl -fsS --max-time 1 "$BASE_URL/healthz" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 0.5
  done

  if [[ "$ready" -ne 1 ]]; then
    echo "错误: port-forward 未就绪，日志如下：" >&2
    cat "$WORKDIR/port-forward.log" >&2 || true
    fail_check "port-forward 未就绪（namespace=$NAMESPACE service=$SERVICE）"
    finish
  fi
}

if [[ -z "$BASE_URL" ]]; then
  start_port_forward
else
  BASE_URL="${BASE_URL%/}"
fi

# 1) liveness
code="$(http_get "$BASE_URL/healthz" "$WORKDIR/health.json" "$WORKDIR/health.hdr")"
if [[ "$code" == "200" ]]; then
  if "$PYTHON_BIN" - "$WORKDIR/health.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
assert data.get("status") == "ok", data
PY
  then
    pass_check "GET /healthz -> 200, JSON status=ok"
  else
    fail_check "GET /healthz -> 200 但 JSON 不符合预期"
  fi
else
  fail_check "GET /healthz -> ${code}（期望 200）"
fi

# 2) readiness
code="$(http_get "$BASE_URL/readyz" "$WORKDIR/ready.json" "$WORKDIR/ready.hdr")"
if [[ "$code" == "200" ]]; then
  if "$PYTHON_BIN" - "$WORKDIR/ready.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
assert data.get("status") == "ready", data
PY
  then
    pass_check "GET /readyz -> 200, JSON status=ready"
  else
    fail_check "GET /readyz -> 200 但 JSON 不符合预期"
  fi
else
  fail_check "GET /readyz -> ${code}（期望 200）"
fi

# 3) version / 发布可追溯
code="$(http_get "$BASE_URL/version" "$WORKDIR/version.json" "$WORKDIR/version.hdr")"
if [[ "$code" == "200" ]]; then
  if "$PYTHON_BIN" - "$WORKDIR/version.json" "$EXPECT_VERSION" "$EXPECT_GIT_SHA" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
version = data.get("app_version")
sha = data.get("git_sha")
assert version, f"app_version missing: {data}"
assert sha, f"git_sha missing: {data}"
if sys.argv[2]:
    assert version == sys.argv[2], f"app_version={version!r}, expected {sys.argv[2]!r}"
if sys.argv[3]:
    assert sha == sys.argv[3], f"git_sha={sha!r}, expected {sys.argv[3]!r}"
PY
  then
    pass_check "GET /version -> 200, app_version/git_sha 可追溯"
  else
    fail_check "GET /version -> 200 但版本字段或期望值不匹配"
  fi
else
  fail_check "GET /version -> ${code}（期望 200）"
fi

# 4) metrics 基线
code="$(http_get "$BASE_URL/metrics" "$WORKDIR/metrics-before.txt" "$WORKDIR/metrics-before.hdr")"
METRICS_BEFORE_OK=0
if [[ "$code" == "200" ]]; then
  if grep -q '^# HELP demo_http_requests_total' "$WORKDIR/metrics-before.txt" \
      && grep -q '^# TYPE demo_http_request_duration_seconds histogram' "$WORKDIR/metrics-before.txt"; then
    pass_check "GET /metrics -> 200, 业务 counter/histogram 已暴露"
    METRICS_BEFORE_OK=1
  else
    fail_check "GET /metrics -> 200 但缺少 demo_http_requests_total / demo_http_request_duration_seconds"
  fi
else
  fail_check "GET /metrics -> ${code}（期望 200）"
fi

# 5) 业务请求 + request_id 关联
REQUEST_ID="acceptance-$$-$(date +%s)"
code="$(http_get "$BASE_URL/work" "$WORKDIR/work.json" "$WORKDIR/work.hdr" "$REQUEST_ID")"
if [[ "$code" == "200" ]]; then
  if "$PYTHON_BIN" - "$WORKDIR/work.json" "$WORKDIR/work.hdr" "$REQUEST_ID" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
request_id = data.get("request_id")
assert request_id, f"request_id missing: {data}"
assert data.get("status") == "ok", data
assert request_id == sys.argv[3], f"request_id={request_id!r}, sent {sys.argv[3]!r}"
headers = {}
with open(sys.argv[2], encoding="utf-8", errors="replace") as fh:
    for line in fh:
        if ":" in line:
            key, value = line.split(":", 1)
            headers[key.strip().lower()] = value.strip()
assert headers.get("x-request-id") == request_id, (headers.get("x-request-id"), request_id)
PY
  then
    pass_check "GET /work -> 200, JSON request_id 与请求/响应头一致"
  else
    fail_check "GET /work -> 200 但 JSON/request_id/响应头不一致"
  fi
else
  fail_check "GET /work -> ${code}（期望 200；当前故障演练配置可能返回 500）"
fi

# 6) metrics 增量 + 固定 route 标签（probes 不得出现在业务 SLI）
code="$(http_get "$BASE_URL/metrics" "$WORKDIR/metrics-after.txt" "$WORKDIR/metrics-after.hdr")"
if [[ "$code" == "200" && "$METRICS_BEFORE_OK" -eq 1 ]]; then
  before="$("$PYTHON_BIN" - "$WORKDIR/metrics-before.txt" <<'PY'
import sys
value = 0.0
with open(sys.argv[1], encoding="utf-8") as fh:
    for line in fh:
        if line.startswith("demo_http_requests_total{") and 'route="/work"' in line and 'status="200"' in line:
            value = float(line.rsplit(" ", 1)[1])
print(value)
PY
)"
  after="$("$PYTHON_BIN" - "$WORKDIR/metrics-after.txt" <<'PY'
import sys
value = 0.0
with open(sys.argv[1], encoding="utf-8") as fh:
    for line in fh:
        if line.startswith("demo_http_requests_total{") and 'route="/work"' in line and 'status="200"' in line:
            value = float(line.rsplit(" ", 1)[1])
print(value)
PY
)"
  if awk -v before="$before" -v after="$after" 'BEGIN { exit !(after > before) }'; then
    pass_check "metrics 中 /work status=200 counter 增加（${before} -> ${after}）"
  else
    fail_check "metrics 中 /work status=200 counter 未增加（${before} -> ${after}）"
  fi
  if grep -q 'route="/healthz"' "$WORKDIR/metrics-after.txt" || grep -q 'route="/readyz"' "$WORKDIR/metrics-after.txt"; then
    fail_check "health/readiness 探针污染了业务 SLI（出现 route=/healthz 或 /readyz）"
  else
    pass_check "health/readiness 探针未写入业务 SLI 标签"
  fi
else
  fail_check "无法取得可比较的 /metrics（HTTP ${code}）"
fi

finish
