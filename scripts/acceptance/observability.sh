#!/usr/bin/env bash
# Stage 3/4 observability acceptance. READ-ONLY: this script only uses
# kubectl get/port-forward and HTTP GET queries. It never deletes, restarts,
# scales, applies, or patches Prometheus/Loki/any cluster object. The two
# persistence/rebuild drills are intentionally left to the main agent; this
# script can only prove the preconditions and the live queries after a drill.
#
# Usage:
#   bash scripts/acceptance/observability.sh --phase storage
#   bash scripts/acceptance/observability.sh --phase metrics
#   bash scripts/acceptance/observability.sh --phase logging
#   bash scripts/acceptance/observability.sh --phase all
#
# Final metrics acceptance requires a same-fingerprint DemoHighErrorRate
# firing+resolved pair, with resolved received after firing. Run a real
# error/recovery drill first. --allow-empty-alerts only skips the completely
# empty receiver case and exits 3; it is never a final pass.
set -uo pipefail

KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
export KUBECONFIG

MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"
LOGGING_NAMESPACE="${LOGGING_NAMESPACE:-logging}"
APP_NAMESPACE="${APP_NAMESPACE:-demo}"
PHASE="all"
ALLOW_EMPTY_ALERTS=0
SMOKE_ONLY=0
REQUIRED_ALERT="${REQUIRED_ALERT:-DemoHighErrorRate}"
PROM_LOCAL="${PROM_LOCAL:-19090}"
LOKI_LOCAL="${LOKI_LOCAL:-13100}"
GRAFANA_LOCAL="${GRAFANA_LOCAL:-13000}"
RECEIVER_LOCAL="${RECEIVER_LOCAL:-18081}"

PASSES=0
FAILS=0
PIDS=()
TMPDIR_RUN="$(mktemp -d "${TMPDIR:-/tmp}/observability-acceptance.XXXXXX")" || exit 2
KUBECTL=(kubectl --request-timeout=15s)

pass() { printf '[PASS] %s\n' "$*"; PASSES=$((PASSES + 1)); }
fail() { printf '[FAIL] %s\n' "$*" >&2; FAILS=$((FAILS + 1)); }
info() { printf '[INFO] %s\n' "$*"; }

cleanup() {
  local pid
  for pid in "${PIDS[@]:-}"; do
    if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  rm -rf "$TMPDIR_RUN"
}
trap cleanup EXIT INT TERM

usage() {
  cat <<'EOF'
用法: scripts/acceptance/observability.sh [选项]

只读验收，不创建/删除/重启集群资源。

选项:
  --phase storage|metrics|logging|all  要检查的阶段（默认 all）
  --allow-empty-alerts                 receiver 完全无事件时跳过告警对检查；
                                       最终退出码 3，不能视为通过
  --help                               显示帮助

环境变量:
  KUBECONFIG                 默认 /etc/kubernetes/admin.conf
  MONITORING_NAMESPACE       默认 monitoring
  LOGGING_NAMESPACE          默认 logging
  APP_NAMESPACE              默认 demo
  REQUIRED_ALERT             默认 DemoHighErrorRate
  PROM_LOCAL/LOKI_LOCAL/GRAFANA_LOCAL/RECEIVER_LOCAL  本地转发端口

退出码:
  0  最终验收检查全部通过
  1  有检查失败
  3  使用了 --allow-empty-alerts 且 receiver 无事件（仅 smoke，不是最终通过）

示例:
  bash scripts/acceptance/observability.sh --phase storage
  bash scripts/acceptance/observability.sh --phase metrics
  bash scripts/acceptance/observability.sh --phase logging
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase)
      PHASE="${2:?--phase 需要参数}"
      shift 2
      ;;
    --allow-empty-alerts)
      ALLOW_EMPTY_ALERTS=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "未知参数: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$PHASE" in
  storage|metrics|logging|all) ;;
  *)
    echo "错误: --phase 必须是 storage、metrics、logging 或 all" >&2
    exit 2
    ;;
esac

for binary in kubectl python3 curl; do
  if ! command -v "$binary" >/dev/null 2>&1; then
    echo "错误: 需要 $binary" >&2
    exit 2
  fi
done

k() { timeout 40 "${KUBECTL[@]}" "$@"; }

json_or_empty() {
  local out
  if out="$("$@" 2>"$TMPDIR_RUN/cmd.err")"; then
    printf '%s' "$out"
  else
    cat "$TMPDIR_RUN/cmd.err" >&2 || true
    return 1
  fi
}

pf_start() {
  local namespace="$1" service="$2" local_port="$3" remote_port="$4" name="$5"
  local log="$TMPDIR_RUN/pf-${name}.log"
  local pid
  kubectl --request-timeout=15s -n "$namespace" port-forward \
    --address 127.0.0.1 "svc/${service}" "${local_port}:${remote_port}" \
    >"$log" 2>&1 &
  pid=$!
  PIDS+=("$pid")
  local i
  for i in $(seq 1 40); do
    if ! kill -0 "$pid" 2>/dev/null; then
      fail "port-forward ${namespace}/${service} 提前退出"
      sed -n '1,10p' "$log" >&2 || true
      return 1
    fi
    if curl -sS --max-time 1 -o /dev/null "http://127.0.0.1:${local_port}/" 2>/dev/null; then
      return 0
    fi
    sleep 0.5
  done
  fail "port-forward ${namespace}/${service} 在 20s 内未就绪"
  sed -n '1,10p' "$log" >&2 || true
  return 1
}

check_prerequisites() {
  if k get --raw=/readyz >/dev/null 2>&1; then
    pass "Kubernetes API /readyz"
  else
    fail "Kubernetes API /readyz 不健康"
    return 1
  fi
  return 0
}

check_nodes() {
  local raw
  if ! raw="$(json_or_empty k get nodes -o json)"; then
    fail "无法读取 nodes"
    return 1
  fi
  if printf '%s' "$raw" | python3 -c '
import json, sys
data = json.load(sys.stdin)
items = data.get("items", [])
assert len(items) == 2, f"expected 2 nodes, got {len(items)}"
control_plane_nodes = []
for node in items:
    name = node["metadata"]["name"]
    conditions = node.get("status", {}).get("conditions", [])
    ready = any(c.get("type") == "Ready" and c.get("status") == "True" for c in conditions)
    assert ready, f"{name} is not Ready"
    labels = node["metadata"].get("labels", {})
    capacity = node.get("status", {}).get("allocatable", {})
    print("node=%s ready=true cpu=%s memory=%s" % (name, capacity.get("cpu"), capacity.get("memory")))
    if "node-role.kubernetes.io/control-plane" in labels:
        control_plane_nodes.append(node)
assert len(control_plane_nodes) == 1, f"expected exactly 1 control-plane node, got {len(control_plane_nodes)}"
control = control_plane_nodes[0]
taints = control.get("spec", {}).get("taints", [])
assert any(t.get("key") == "node-role.kubernetes.io/control-plane" and t.get("effect") == "NoSchedule" for t in taints), \
    "control-plane NoSchedule taint is absent"
print("control-plane NoSchedule taint=present")
'; then
    pass "两节点 Ready，控制面保留 NoSchedule taint"
  else
    fail "节点数量/Ready/控制面 taint 检查失败"
  fi
}

check_storage_class() {
  local sc deploy
  if ! sc="$(json_or_empty k get storageclass local-path -o json)"; then
    fail "无法读取 local-path StorageClass"
    return
  fi
  if printf '%s' "$sc" | python3 -c '
import json, sys
sc = json.load(sys.stdin)
assert sc.get("provisioner") == "rancher.io/local-path", sc.get("provisioner")
assert sc.get("volumeBindingMode") == "WaitForFirstConsumer", sc.get("volumeBindingMode")
assert sc.get("reclaimPolicy") == "Delete", sc.get("reclaimPolicy")
assert sc.get("metadata", {}).get("annotations", {}).get("storageclass.kubernetes.io/is-default-class") == "true", \
    "local-path is not the default StorageClass"
print("local-path default=true WaitForFirstConsumer=true reclaimPolicy=Delete")
'; then
    pass "local-path StorageClass 参数正确且为默认类"
  else
    fail "local-path StorageClass 参数/默认标记不正确"
  fi

  if ! deploy="$(json_or_empty k -n local-path-storage get deployment local-path-provisioner -o json)"; then
    fail "local-path provisioner Deployment 不存在"
    return
  fi
  if printf '%s' "$deploy" | python3 -c '
import json, sys
d = json.load(sys.stdin)
status = d.get("status", {})
assert status.get("observedGeneration", 0) >= d["metadata"].get("generation", 1)
assert status.get("availableReplicas", 0) >= 1, status
print("local-path provisioner available")
'; then
    pass "local-path provisioner Deployment 可用"
  else
    fail "local-path provisioner 未就绪"
  fi
}

check_pvcs() {
  local namespace="$1"
  shift
  local pvcs
  if ! pvcs="$(json_or_empty k -n "$namespace" get pvc -o json)"; then
    fail "无法读取 ${namespace} PVC"
    return
  fi
  if printf '%s' "$pvcs" | python3 -c '
import json, sys
data = json.load(sys.stdin)
required = sys.argv[1:]
items = data.get("items", [])
assert items, "no PVCs found"
capacities = set()
for pvc in items:
    name = pvc["metadata"]["name"]
    phase = pvc.get("status", {}).get("phase")
    sc = pvc.get("spec", {}).get("storageClassName")
    cap = pvc.get("status", {}).get("capacity", {}).get("storage") or pvc.get("spec", {}).get("resources", {}).get("requests", {}).get("storage")
    assert phase == "Bound", f"{name} phase={phase}"
    assert sc == "local-path", f"{name} storageClassName={sc}"
    capacities.add(cap)
    print(f"pvc={name} capacity={cap} phase={phase} storageClass={sc}")
for size in required:
    assert size in capacities, f"required PVC size {size} not found; got {sorted(capacities)}"
' "$@"; then
    pass "PVC 全部 Bound 且使用 local-path（required=$*）"
  else
    fail "PVC 状态/大小/StorageClass 不符合预期"
  fi
}

check_pv_reclaim() {
  local namespace="$1" pvs
  if ! pvs="$(json_or_empty k get pv -o json)"; then
    fail "无法读取 PV"
    return
  fi
  if printf '%s' "$pvs" | python3 -c '
import json, sys
namespace = sys.argv[1]
data = json.load(sys.stdin)
matched = 0
for pv in data.get("items", []):
    ref = pv.get("spec", {}).get("claimRef", {})
    if ref.get("namespace") != namespace:
        continue
    matched += 1
    assert pv.get("status", {}).get("phase") == "Bound", pv["metadata"]["name"]
    assert pv.get("spec", {}).get("persistentVolumeReclaimPolicy") == "Delete", pv["metadata"]["name"]
    print("pv=%s reclaimPolicy=Delete phase=Bound" % pv["metadata"]["name"])
assert matched > 0, f"no PV bound in {namespace}"
' "$namespace"; then
    pass "${namespace} 的 PV 均为 Bound，reclaimPolicy=Delete"
  else
    fail "${namespace} 的 PV 状态/reclaimPolicy 不符合预期"
  fi
}

check_metrics() {
  local prom_svc="${MONITORING_NAMESPACE}-kube-prometheus-prometheus"
  local am_svc="${MONITORING_NAMESPACE}-kube-prometheus-alertmanager"
  local targets rules

  if ! k -n "$MONITORING_NAMESPACE" get svc "$prom_svc" >/dev/null 2>&1; then
    fail "Prometheus Service ${MONITORING_NAMESPACE}/${prom_svc} 不存在"
    return
  fi
  if ! pf_start "$MONITORING_NAMESPACE" "$prom_svc" "$PROM_LOCAL" 9090 prometheus; then
    return
  fi
  if ! targets="$(curl -fsS --max-time 15 "http://127.0.0.1:${PROM_LOCAL}/api/v1/targets?state=active")"; then
    fail "无法通过 Prometheus API 查询 active targets"
    return
  fi
  if printf '%s' "$targets" | python3 -c '
import json, sys
data = json.load(sys.stdin)
active = data.get("data", {}).get("activeTargets", [])
assert active, "no active targets"
down = [(t.get("scrapePool"), t.get("lastError")) for t in active if t.get("health") != "up"]
assert not down, f"unhealthy active targets: {down}"
print(f"all active targets up: {len(active)}")

def pool(t):
    return (t.get("scrapePool") or "") + " " + (t.get("labels", {}).get("job") or "")

node_targets = [t for t in active if "node-exporter" in pool(t).lower() and t.get("health") == "up"]
node_ids = sorted({(t.get("labels", {}).get("node") or t.get("labels", {}).get("instance") or "?") for t in node_targets})
assert len(node_targets) >= 2, f"node-exporter active targets={len(node_targets)}"
assert len(node_ids) >= 2, f"node-exporter distinct nodes={node_ids}"
print(f"node-exporter targets={len(node_targets)} nodes={node_ids}")

ksm = [t for t in active if "kube-state-metrics" in pool(t).lower() and t.get("health") == "up"]
assert ksm, "no healthy kube-state-metrics target"
print(f"kube-state-metrics targets={len(ksm)}")

demo = [t for t in active if t.get("labels", {}).get("namespace") == "demo" and t.get("health") == "up"]
assert demo, "no healthy demo target in namespace demo"
print("demo targets=%s pools=%s" % (len(demo), sorted({t.get("scrapePool") for t in demo})))
'; then
    pass "Prometheus targets：node-exporter 两节点、KSM、demo 均 active/up"
  else
    fail "Prometheus targets 缺少 node-exporter 两节点/KSM/demo"
  fi

  if ! rules="$(curl -fsS --max-time 15 "http://127.0.0.1:${PROM_LOCAL}/api/v1/rules")"; then
    fail "无法查询 Prometheus rules"
    return
  fi
  if printf '%s' "$rules" | python3 -c '
import json, re, sys
data = json.load(sys.stdin)
groups = data.get("data", {}).get("groups", [])
group = next((g for g in groups if g.get("name") == "demo-slo"), None)
alert_group = next((g for g in groups if g.get("name") == "demo-alerts"), None)
assert group and alert_group, "demo-slo/demo-alerts group missing"
records = {r.get("name"): r for r in group.get("rules", [])}
alerts = {r.get("name"): r for r in alert_group.get("rules", [])}
for name in ["demo:sli_availability:ratio_7d", "demo:http_errors:ratio_5m", "demo:http_requests:rate_5m", "demo:slo_target:ratio", "demo:slo_error_budget:ratio_7d"]:
    assert name in records, f"record {name} missing"
for name in ["DemoHighErrorRate", "DemoP95LatencyHigh", "DemoUnavailable", "DemoPodCrashLooping"]:
    assert name in alerts, f"alert {name} missing"
slo = records["demo:sli_availability:ratio_7d"].get("query", "")
assert re.search(r"and\s+on\s*\(\s*\)", slo) and re.search(r">\s*0", slo), "availability rule lacks no-traffic guard"
for name, rule in alerts.items():
    assert rule.get("health") == "ok", "unhealthy rule: %s %s" % (name, rule.get("health"))
    duration = rule.get("duration")
    if duration is not None:
        assert duration <= 60, f"{name} duration={duration}s, expected <=60s for the drill"
print("rules: 5 recordings + 4 alerts present; 1m drill duration; SLO rule has no-traffic guard")
'; then
    pass "Demo 规则组完整（1m 演练告警、7d SLI/SLO 记录、无流量保护）"
  else
    fail "Demo 规则组缺失或不符合设计"
  fi

  local requests buckets target
  if ! requests="$(curl -fsS --get --max-time 15 --data-urlencode 'query=count(demo_http_requests_total{namespace="demo",route="/work"})' "http://127.0.0.1:${PROM_LOCAL}/api/v1/query")"; then
    fail "无法查询 demo_http_requests_total"
  else
    if printf '%s' "$requests" | python3 -c '
import json, sys
data = json.load(sys.stdin)
result = data.get("data", {}).get("result", [])
assert result and float(result[0]["value"][1]) > 0
print("demo_http_requests_total sample present")
'; then
      pass "Prometheus 实际查询到 demo_http_requests_total{route=/work}"
    else
      fail "Prometheus 没有 demo_http_requests_total{route=/work} 样本（先产生真实流量）"
    fi
  fi

  if ! buckets="$(curl -fsS --get --max-time 15 --data-urlencode 'query=count(demo_http_request_duration_seconds_bucket{namespace="demo",route="/work"})' "http://127.0.0.1:${PROM_LOCAL}/api/v1/query")"; then
    fail "无法查询 demo histogram buckets"
  else
    if printf '%s' "$buckets" | python3 -c '
import json, sys
data = json.load(sys.stdin)
result = data.get("data", {}).get("result", [])
assert result and float(result[0]["value"][1]) > 0
print("demo_http_request_duration_seconds_bucket samples present")
'; then
      pass "Prometheus 实际查询到 demo_http_request_duration_seconds buckets"
    else
      fail "Prometheus 没有 demo histogram bucket 样本"
    fi
  fi

  if ! target="$(curl -fsS --get --max-time 15 --data-urlencode 'query=demo:slo_target:ratio' "http://127.0.0.1:${PROM_LOCAL}/api/v1/query")"; then
    fail "无法查询 demo:slo_target:ratio"
  else
    if printf '%s' "$target" | python3 -c '
import json, sys
data = json.load(sys.stdin)
result = data.get("data", {}).get("result", [])
assert result and abs(float(result[0]["value"][1]) - 0.999) < 1e-9
print("SLO target=0.999")
'; then
      pass "7d SLO 目标记录为 0.999"
    else
      fail "SLO 目标记录不是 0.999"
    fi
  fi

  # Alertmanager generated config: prove send_resolved and the local webhook.
  if k -n "$MONITORING_NAMESPACE" get secrets -o json 2>/dev/null | python3 -c '
import base64, json, re, sys
data = json.load(sys.stdin)
for item in data.get("items", []):
    encoded = item.get("data", {}).get("alertmanager.yaml")
    if not encoded:
        continue
    cfg = base64.b64decode(encoded).decode("utf-8", errors="replace")
    assert re.search(r"send_resolved:\s*true", cfg), "send_resolved is not true"
    assert "alert-receiver.monitoring.svc.cluster.local:8080/alerts" in cfg, "local webhook is absent"
    print("alertmanager config secret=%s" % item["metadata"]["name"])
    sys.exit(0)
sys.exit(1)
'; then
    pass "Alertmanager 实际配置含 send_resolved=true 和本地 webhook"
  else
    fail "Alertmanager 配置未证明 send_resolved=true/本地 webhook"
  fi

  if k -n "$MONITORING_NAMESPACE" get svc alert-receiver >/dev/null 2>&1 \
      && pf_start "$MONITORING_NAMESPACE" alert-receiver "$RECEIVER_LOCAL" 8080 receiver; then
    local health events
    if ! health="$(curl -fsS --max-time 10 "http://127.0.0.1:${RECEIVER_LOCAL}/healthz")"; then
      fail "alert receiver /healthz 查询失败"
    else
      if printf '%s' "$health" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("status")=="ok"'; then
        pass "alert receiver /healthz 正常"
      else
        fail "alert receiver /healthz 返回异常"
      fi
    fi
    if ! events="$(curl -fsS --max-time 10 "http://127.0.0.1:${RECEIVER_LOCAL}/alerts?limit=500")"; then
      fail "alert receiver /alerts 查询失败"
    else
      if printf '%s' "$events" | python3 -c '
import hashlib, json, sys
from datetime import datetime, timedelta

required = sys.argv[1]
data = json.load(sys.stdin)
events = data.get("events", [])
assert isinstance(events, list)
if not events:
    sys.exit(3)

def parse_utc(value):
    assert value, "received_at missing"
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    assert parsed.tzinfo is not None, f"received_at has no timezone: {value}"
    assert parsed.utcoffset() == timedelta(0), f"received_at is not UTC: {value}"
    return parsed

def fingerprint(alert):
    fp = alert.get("fingerprint")
    if fp:
        return str(fp), "alert.fingerprint"
    labels = alert.get("labels") or {}
    canonical = json.dumps(labels, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()[:16], "derived(labels)"

series = {}
seen = []
for event in events:
    received = parse_utc(event.get("received_at"))
    alert = event.get("alert") or {}
    labels = alert.get("labels") or {}
    name = labels.get("alertname")
    status = str(alert.get("status", "")).lower()
    if name != required:
        continue
    if status not in {"firing", "resolved"}:
        continue
    fp, source = fingerprint(alert)
    series.setdefault(fp, []).append((received, status, source))
    seen.append((fp, status, event.get("received_at")))

valid = []
for fp, entries in series.items():
    firings = [entry for entry in entries if entry[1] == "firing"]
    resolved = [entry for entry in entries if entry[1] == "resolved"]
    for firing in firings:
        after = [entry for entry in resolved if entry[0] > firing[0]]
        if after:
            resolved_entry = max(after, key=lambda entry: entry[0])
            valid.append((firing[0], resolved_entry[0], fp, firing[2]))
            break

if not valid:
    print(
        "no same-fingerprint %s firing->resolved pair; recent=%s"
        % (required, seen[-8:]),
        file=sys.stderr,
    )
    sys.exit(4)
firing_at, resolved_at, fp, source = max(valid, key=lambda item: item[1])
assert resolved_at > firing_at, "resolved record is not after firing"
print(
    "receiver validated alert=%s fingerprint=%s source=%s firing_at=%s resolved_at=%s events=%s"
    % (required, fp, source, firing_at.isoformat(), resolved_at.isoformat(), len(events))
)
' "$REQUIRED_ALERT"; then
        pass "alert receiver 有同一 fingerprint 的 ${REQUIRED_ALERT} firing/resolved 记录，且恢复晚于触发"
      else
        rc=$?
        if [[ "$rc" -eq 3 ]]; then
          if [[ "$ALLOW_EMPTY_ALERTS" -eq 1 ]]; then
            info "alert receiver 暂无事件（--allow-empty-alerts smoke，退出码 3，不能作为最终验收）"
            SMOKE_ONLY=1
          else
            fail "alert receiver 暂无事件；先完成 ${REQUIRED_ALERT} 真实故障/恢复演练，再运行最终验收"
          fi
        elif [[ "$rc" -eq 4 ]]; then
          fail "alert receiver 有事件，但没有同一 fingerprint 的 ${REQUIRED_ALERT} firing/resolved 对，或恢复不在触发之后"
        else
          fail "alert receiver 事件 JSON/UTC/fingerprint 结构异常"
        fi
      fi
    fi
  else
    fail "alert receiver Service/Pod 不可用"
  fi

  # Grafana datasources and dashboard: use the generated admin Secret, never
  # print it. If the Secret is absent, fail rather than pretend.
  local guser gpass grafana_svc
  grafana_svc="${MONITORING_NAMESPACE}-grafana"
  if ! k -n "$MONITORING_NAMESPACE" get svc "$grafana_svc" >/dev/null 2>&1; then
    fail "Grafana Service ${grafana_svc} 不存在"
    return
  fi
  if k -n "$MONITORING_NAMESPACE" get secret grafana-admin >/dev/null 2>&1; then
    guser="$(k -n "$MONITORING_NAMESPACE" get secret grafana-admin -o jsonpath='{.data.admin-user}' | base64 -d)"
    gpass="$(k -n "$MONITORING_NAMESPACE" get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)"
  elif k -n "$MONITORING_NAMESPACE" get secret "${MONITORING_NAMESPACE}-grafana" >/dev/null 2>&1; then
    guser="$(k -n "$MONITORING_NAMESPACE" get secret "${MONITORING_NAMESPACE}-grafana" -o jsonpath='{.data.admin-user}' | base64 -d)"
    gpass="$(k -n "$MONITORING_NAMESPACE" get secret "${MONITORING_NAMESPACE}-grafana" -o jsonpath='{.data.admin-password}' | base64 -d)"
  else
    fail "找不到 Grafana admin Secret（grafana-admin 或 ${MONITORING_NAMESPACE}-grafana）"
    return
  fi
  if [[ -z "$guser" || -z "$gpass" ]]; then
    fail "Grafana admin Secret 字段为空"
    return
  fi

  if ! pf_start "$MONITORING_NAMESPACE" "$grafana_svc" "$GRAFANA_LOCAL" 80 grafana; then
    return
  fi
  local datasources code
  if ! datasources="$(curl -fsS --max-time 10 -u "${guser}:${gpass}" "http://127.0.0.1:${GRAFANA_LOCAL}/api/datasources")"; then
    fail "Grafana /api/datasources 查询失败"
  else
    if printf '%s' "$datasources" | python3 -c '
import json, sys
data = json.load(sys.stdin)
types = {d.get("type") for d in data}
assert "prometheus" in types, f"prometheus datasource missing: {types}"
assert "loki" in types, f"loki datasource missing: {types}"
print(f"datasources={sorted(types)}")
'; then
      pass "Grafana 数据源包含 Prometheus 和 Loki"
    else
      fail "Grafana 缺少 Prometheus/Loki 数据源"
    fi
  fi

  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -u "${guser}:${gpass}" "http://127.0.0.1:${GRAFANA_LOCAL}/api/dashboards/uid/demo-observability" || true)"
  if [[ "$code" == "200" ]]; then
    pass "Grafana dashboard uid=demo-observability 可查询"
  else
    fail "Grafana dashboard uid=demo-observability HTTP ${code:-000}"
  fi
  unset gpass
}

check_logging() {
  local logs_svc="loki"
  local alloy node_values expected_nodes start end
  if ! k -n "$LOGGING_NAMESPACE" get svc "$logs_svc" >/dev/null 2>&1; then
    fail "Loki Service ${LOGGING_NAMESPACE}/${logs_svc} 不存在"
    return
  fi
  if ! pf_start "$LOGGING_NAMESPACE" "$logs_svc" "$LOKI_LOCAL" 3100 loki; then
    return
  fi
  if ! curl -fsS --max-time 10 "http://127.0.0.1:${LOKI_LOCAL}/ready" >/dev/null; then
    fail "Loki /ready 不健康"
  else
    pass "Loki /ready 正常"
  fi

  expected_nodes="$(k get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"
  if ! node_values="$(curl -fsS --max-time 15 "http://127.0.0.1:${LOKI_LOCAL}/loki/api/v1/label/node/values")"; then
    fail "Loki /label/node/values 查询失败"
    return
  fi

  local attempt ok=0
  for attempt in $(seq 1 18); do
    if printf '%s' "$node_values" | python3 -c '
import json, sys
expected = [x for x in sys.argv[1].splitlines() if x.strip()]
values = set(json.load(sys.stdin).get("data", []))
missing = [n for n in expected if n not in values]
assert not missing, f"missing nodes in Loki labels: {missing}; got {sorted(values)}"
print(f"loki node labels={sorted(values)}")
' "$expected_nodes"; then
      ok=1
      break
    fi
    sleep 5
    node_values="$(curl -fsS --max-time 15 "http://127.0.0.1:${LOKI_LOCAL}/loki/api/v1/label/node/values" 2>/dev/null || true)"
  done
  if [[ "$ok" -eq 1 ]]; then
    pass "Loki node 标签包含 master 和 worker 两节点"
  else
    fail "Loki node 标签未覆盖两节点（Alloy 可能尚未采集）"
  fi

  start="$(date -u -d '24 hours ago' +%s)000000000"
  end="$(date -u +%s)000000000"
  local node query_result
  ok=0
  for attempt in $(seq 1 18); do
    ok=1
    while IFS= read -r node; do
      [[ -z "$node" ]] && continue
      if ! query_result="$(curl -fsS --get --max-time 15 \
          --data-urlencode "query={node=\"${node}\"}" \
          --data-urlencode "start=${start}" \
          --data-urlencode "end=${end}" \
          --data-urlencode "limit=1" \
          "http://127.0.0.1:${LOKI_LOCAL}/loki/api/v1/query_range")"; then
        ok=0
        break
      fi
      if ! printf '%s' "$query_result" | python3 -c '
import json, sys
data = json.load(sys.stdin)
result = data.get("data", {}).get("result", [])
assert result, "no streams"
assert any(stream.get("values") for stream in result), "streams have no values"
'; then
        ok=0
        break
      fi
    done <<< "$expected_nodes"
    if [[ "$ok" -eq 1 ]]; then
      break
    fi
    sleep 5
  done
  if [[ "$ok" -eq 1 ]]; then
    pass "Loki 对 master 和 worker 均有真实日志流"
  else
    fail "Loki 未能按 node 查询到两节点日志"
  fi

  if ! alloy="$(json_or_empty k -n "$LOGGING_NAMESPACE" get daemonset alloy -o json)"; then
    fail "Alloy DaemonSet 不存在"
    return
  fi
  if printf '%s' "$alloy" | python3 -c '
import json, sys
d = json.load(sys.stdin)
status = d.get("status", {})
desired = status.get("desiredNumberScheduled", 0)
ready = status.get("numberReady", 0)
assert desired >= 2, f"Alloy desired={desired}"
assert ready >= 2, f"Alloy ready={ready}"
template = d["spec"]["template"]["spec"]
assert not template.get("nodeSelector"), "unexpected nodeSelector: %s" % template.get("nodeSelector")
tolerations = template.get("tolerations", [])
assert any(t.get("operator") == "Exists" for t in tolerations), f"no Exists toleration: {tolerations}"
container = template["containers"][0]
mounts = {m.get("mountPath"): m for m in container.get("volumeMounts", [])}
assert mounts.get("/var/log/pods", {}).get("readOnly") is True, "Alloy /var/log/pods mount is not readOnly"
volumes = {v.get("name"): v for v in template.get("volumes", [])}
host_paths = [v.get("hostPath", {}).get("path") for v in volumes.values()]
assert "/var/log/pods" in host_paths, f"/var/log/pods hostPath missing: {host_paths}"
print(f"alloy desired={desired} ready={ready} hostPath=/var/log/pods readOnly=true")
'; then
    pass "Alloy DaemonSet 两节点就绪、容忍 master taint、只读挂载 /var/log/pods"
  else
    fail "Alloy DaemonSet 调度/挂载/容忍度不符合设计"
  fi

  if check_pvcs "$LOGGING_NAMESPACE" 10Gi; then :; fi
  if check_pv_reclaim "$LOGGING_NAMESPACE"; then :; fi
}

check_monitoring_pvcs() {
  check_pvcs "$MONITORING_NAMESPACE" 10Gi 2Gi 1Gi
  check_pv_reclaim "$MONITORING_NAMESPACE"
}

echo "== Stage 3/4 observability acceptance =="
echo "phase=${PHASE} namespaces=${MONITORING_NAMESPACE}/${LOGGING_NAMESPACE}/${APP_NAMESPACE}"
echo "read-only: no delete/restart/apply operations"
if ! check_prerequisites; then
  echo "acceptance aborted: API unavailable" >&2
  exit 1
fi

check_nodes

case "$PHASE" in
  storage)
    # Storage phase is meaningful before monitoring/logging exist: do not
    # require their PVCs here. Existing PVCs are checked by metrics/all/logging.
    check_storage_class
    ;;
  metrics)
    check_storage_class
    check_monitoring_pvcs
    check_metrics
    ;;
  logging)
    check_storage_class
    check_logging
    ;;
  all)
    check_storage_class
    check_monitoring_pvcs
    check_metrics
    check_logging
    ;;
esac

echo "acceptance summary: checks=$((PASSES + FAILS)) passes=${PASSES} failures=${FAILS}"
if [[ "$FAILS" -gt 0 ]]; then
  exit 1
fi
if [[ "$SMOKE_ONLY" -eq 1 ]]; then
  echo "RESULT: SMOKE_ONLY (required alert firing/resolved pair was not verified; not final acceptance)" >&2
  exit 3
fi
exit 0
