#!/usr/bin/env bash
# 注入一个 demo 演练故障：error / latency / startup-failure。
# 只 patch namespace=demo、标签选中的唯一 Deployment 的 env；不修改其它资源。
# 默认拒绝在 Argo auto-sync 开启时直接 patch；必须显式 --suspend-gitops。
set -u -o pipefail

DRILLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${DRILLS_DIR}/lib.sh"

FAULT=""
SUSPEND_GITOPS=0
LATENCY_MS="${DRILL_LATENCY_MS:-3000}"
ALERT_WAIT="${DRILL_ALERT_WAIT_SECONDS:-30}"
STARTUP_WAIT="${DRILL_STARTUP_OBSERVE_SECONDS:-45}"
ROLLOUT_TIMEOUT="${DRILL_ROLLOUT_TIMEOUT:-180s}"
STARTUP_ROLLOUT_TIMEOUT="${DRILL_STARTUP_ROLLOUT_TIMEOUT:-30s}"

DRILL_ID=""
STATE_FILE=""
PATCHED=0
SUSPENDED=0
COMPLETED=0

usage() {
  cat <<'EOF'
用法: scripts/drills/inject.sh --fault error|latency|startup-failure [选项]

选项:
  --fault TYPE              error: 100% /work 500；latency: 注入延迟；
                            startup-failure: 新 Pod 启动失败（旧 Pod 仍服务）
  --suspend-gitops          显式允许临时关闭 Argo Application demo 自动同步
  --latency-ms N            延迟毫秒（默认 3000，最大 60000）
  --alert-wait SEC          注入后等待 alert receiver 的秒数（默认 30）
  --startup-observe SEC     启动失败观察秒数（默认 45）
  -h, --help

安全默认：如果 Argo Application demo 的 automated sync 已启用，必须传
--suspend-gitops；脚本只关闭/恢复 demo 一个 Application，并在 .state/ 保存原值。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fault) FAULT="${2:?--fault 需要参数}"; shift 2 ;;
    --suspend-gitops) SUSPEND_GITOPS=1; shift ;;
    --latency-ms) LATENCY_MS="${2:?--latency-ms 需要参数}"; shift 2 ;;
    --alert-wait) ALERT_WAIT="${2:?--alert-wait 需要参数}"; shift 2 ;;
    --startup-observe) STARTUP_WAIT="${2:?--startup-observe 需要参数}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$FAULT" in
  error|latency|startup-failure) ;;
  *) echo "错误: --fault 必须是 error|latency|startup-failure" >&2; usage >&2; exit 2 ;;
esac
[[ "$LATENCY_MS" =~ ^[0-9]+$ ]] || die "--latency-ms 必须是非负整数"
(( LATENCY_MS <= 60000 )) || die "--latency-ms 不能超过 60000"
[[ "$ALERT_WAIT" =~ ^[0-9]+$ ]] || die "--alert-wait 必须是非负整数"
[[ "$STARTUP_WAIT" =~ ^[0-9]+$ ]] || die "--startup-observe 必须是非负整数"

require_cmds kubectl curl python3 timeout
ensure_dirs

DRILL_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM"
STATE_FILE="${STATE_DIR}/${DRILL_ID}.json"
STARTED_UTC="$(utc_now)"

cleanup() {
  stop_port_forward
  if (( COMPLETED == 0 )) && { (( PATCHED == 1 )) || (( SUSPENDED == 1 )); }; then
    warn "演练未完成，执行受控恢复：${STATE_FILE}"
    bash "${DRILLS_DIR}/recover.sh" --state "$STATE_FILE" --quiet || warn "自动恢复失败；请立即手工执行 recover.sh"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

select_deployment
if ! start_port_forward; then
  die "无法建立 demo Service 的本地 port-forward"
fi
if ! wait_for_health 30; then
  die "注入前 /healthz 或 /readyz 不健康；拒绝演练"
fi
BASELINE_HEALTH_UTC="$(utc_now)"

APP_JSON="${STATE_DIR}/${DRILL_ID}-application.json"
ARGO_ERR="${STATE_DIR}/${DRILL_ID}-argo.err"
APP_FOUND=0
if k -n "$ARGO_NAMESPACE" get application "$ARGO_APPLICATION" -o json >"$APP_JSON" 2>"$ARGO_ERR"; then
  APP_FOUND=1
else
  if grep -Eiq 'not found|doesn.t have a resource type|no matches for kind|could not find the requested resource' "$ARGO_ERR"; then
    APP_FOUND=0
    rm -f "$APP_JSON"
  else
    die "无法确认 Argo Application ${ARGO_NAMESPACE}/${ARGO_APPLICATION}，拒绝继续: $(tr '\n' ' ' < "$ARGO_ERR" | cut -c1-300)"
  fi
fi

# 先保存完整原状态：Deployment env 与 Application automated policy。
DEPLOY_JSON="${STATE_DIR}/${DRILL_ID}-deployment-before.json"
k -n "$NAMESPACE" get deployment "$DEPLOYMENT" -o json >"$DEPLOY_JSON" || die "无法保存 Deployment 原状态"

if (( APP_FOUND == 1 )); then
  python3 - "$APP_JSON" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    app = json.load(fh)
assert app.get("metadata", {}).get("name") == "demo", app.get("metadata")
assert app.get("spec", {}).get("project") == "demo", "Application project must be demo"
PY
fi

python3 - "$DEPLOY_JSON" "$APP_JSON" "$STATE_FILE" "$DRILL_ID" "$FAULT" "$STARTED_UTC" "$APP_FOUND" <<'PY'
import json
import sys

deploy_path, app_path, state_path, drill_id, fault, started, found = sys.argv[1:8]
with open(deploy_path, encoding="utf-8") as fh:
    deploy = json.load(fh)
containers = deploy["spec"]["template"]["spec"]["containers"]
idx = next(i for i, c in enumerate(containers) if c["name"] == "demo-service")
container = containers[idx]
state = {
    "schema_version": 1,
    "drill_id": drill_id,
    "fault_type": fault,
    "started_utc": started,
    "namespace": "demo",
    "deployment": "demo",
    "application": "demo",
    "application_namespace": "argocd",
    "application_found": found == "1",
    "container_index": idx,
    "container_name": "demo-service",
    "env_present": "env" in container,
    "original_env": container.get("env", []),
    "image": container.get("image"),
    "auto_sync_was_enabled": False,
    "original_automated": None,
    "gitops_suspended": False,
    "fault_patched": False,
}
if found == "1":
    with open(app_path, encoding="utf-8") as fh:
        app = json.load(fh)
    assert app["metadata"]["name"] == "demo"
    assert app["spec"]["project"] == "demo"
    sync = app.get("spec", {}).get("syncPolicy") or {}
    if sync.get("automated") is not None:
        state["original_automated"] = sync["automated"]
        state["auto_sync_was_enabled"] = True
with open(state_path, "w", encoding="utf-8") as fh:
    json.dump(state, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
PY
[[ -s "$STATE_FILE" ]] || die "状态文件写入失败"
printf '%s\n' "$STATE_FILE" >"${STATE_DIR}/latest" || die "无法写入 .state/latest"

update_state() {
  local key="$1" value="$2"
  python3 - "$STATE_FILE" "$key" "$value" <<'PY'
import json, sys
path, key, value = sys.argv[1:4]
with open(path, encoding="utf-8") as fh:
    state = json.load(fh)
state[key] = True if value == "__TRUE__" else False if value == "__FALSE__" else value
with open(path, "w", encoding="utf-8") as fh:
    json.dump(state, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
PY
}

AUTO_SYNC_ENABLED="$(python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print(1 if s["auto_sync_was_enabled"] else 0)' "$STATE_FILE")"

if (( AUTO_SYNC_ENABLED == 1 )); then
  if (( SUSPEND_GITOPS == 0 )); then
    die "Argo Application demo 的 auto-sync 已启用；请加 --suspend-gitops（仅暂停 demo）后重试"
  fi
  echo "临时暂停 Argo Application ${ARGO_NAMESPACE}/${ARGO_APPLICATION} 自动同步（仅 demo）" >&2
  k -n "$ARGO_NAMESPACE" patch application "$ARGO_APPLICATION" --type=merge \
    -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null || die "暂停 Argo auto-sync 失败"
  SUSPENDED=1
  update_state gitops_suspended __TRUE__
fi

case "$FAULT" in
  error)
    ENV_UPDATE=(DEMO_ERROR_RATE=1 DEMO_LATENCY_MS=0 DEMO_STARTUP_FAIL=false)
    ;;
  latency)
    ENV_UPDATE=(DEMO_ERROR_RATE=0 "DEMO_LATENCY_MS=${LATENCY_MS}" DEMO_STARTUP_FAIL=false)
    ;;
  startup-failure)
    ENV_UPDATE=(DEMO_ERROR_RATE=0 DEMO_LATENCY_MS=0 DEMO_STARTUP_FAIL=true)
    ;;
esac

if ! k -n "$NAMESPACE" set env "deployment/${DEPLOYMENT}" "${ENV_UPDATE[@]}" >/dev/null; then
  die "只 patch Deployment env 失败"
fi
PATCHED=1
update_state fault_patched __TRUE__
FAULT_APPLIED_UTC="$(utc_now)"

jsonl "$LOG_FILE" \
  "event=fault_started" \
  "drill_id=${DRILL_ID}" \
  "fault_type=${FAULT}" \
  "namespace=${NAMESPACE}" \
  "deployment=${DEPLOYMENT}" \
  "fault_started_utc=${FAULT_APPLIED_UTC}" \
  "baseline_health_utc=${BASELINE_HEALTH_UTC}" \
  "gitops_suspended=$([[ "$SUSPENDED" -eq 1 ]] && printf '%s' '__TRUE__' || printf '%s' '__FALSE__')" \
  "alert_fired=__NULL__" \
  "root_cause_confirmed=__FALSE__" \
  "root_cause_evidence=__NULL__" \
  "evidence_command=kubectl -n demo get deploy demo -o json"

if [[ "$FAULT" == "startup-failure" ]]; then
  # maxUnavailable=0 时，新 Pod CrashLoop 不淘汰旧 Pod；旧 Pod 继续服务。
  # 因此这里不能把 rollout 失败当成“业务完全不可用”，只记录发布保护证据。
  if wait_for_rollout "$STARTUP_ROLLOUT_TIMEOUT"; then
    warn "startup-failure 的 rollout 意外完成；仍记录实际观测结果"
  fi
  sleep "$STARTUP_WAIT"

  POD_ROWS="$(k -n "$NAMESPACE" get pods -l "$LABEL_SELECTOR" \
    -o jsonpath='{range .items[*]}{.metadata.creationTimestamp}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
  NEWEST_POD="$(printf '%s\n' "$POD_ROWS" | sed '/^[[:space:]]*$/d' | sort | tail -n 1 | awk '{print $2}')"
  POD_LIST="$(k -n "$NAMESPACE" get pods -l "$LABEL_SELECTOR" -o wide --no-headers 2>&1 | tr '\n' ';' | cut -c1-800 || true)"
  CRASH_LOGS=""
  if [[ -n "$NEWEST_POD" ]]; then
    CRASH_LOGS="$(timeout 15s kubectl --request-timeout="$KUBECTL_REQUEST_TIMEOUT" -n "$NAMESPACE" logs "$NEWEST_POD" --tail=30 2>&1 || timeout 15s kubectl --request-timeout="$KUBECTL_REQUEST_TIMEOUT" -n "$NAMESPACE" logs "$NEWEST_POD" --previous --tail=30 2>&1 || true)"
  fi
  CRASH_LOGS="$(printf '%s' "$CRASH_LOGS" | tr '\n' ';' | cut -c1-1200)"
  READY_REPLICAS="$(k -n "$NAMESPACE" get deployment "$DEPLOYMENT" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  UPDATED_REPLICAS="$(k -n "$NAMESPACE" get deployment "$DEPLOYMENT" -o jsonpath='{.status.updatedReplicas}' 2>/dev/null || true)"
  [[ -n "$READY_REPLICAS" ]] || READY_REPLICAS=0
  [[ -n "$UPDATED_REPLICAS" ]] || UPDATED_REPLICAS=0

  OLD_SERVING=0
  if health_ok; then
    OLD_SERVING=1
  fi
  HEALTH_OBSERVED_UTC="$(utc_now)"
  jsonl "$LOG_FILE" \
    "event=startup_failure_observed" \
    "drill_id=${DRILL_ID}" \
    "fault_type=startup-failure" \
    "pod_name=${NEWEST_POD:-__NULL__}" \
    "ready_replicas=${READY_REPLICAS}" \
    "updated_replicas=${UPDATED_REPLICAS}" \
    "old_pod_still_serving=$([[ "$OLD_SERVING" -eq 1 ]] && printf '%s' '__TRUE__' || printf '%s' '__FALSE__')" \
    "fault_fully_effective=__FALSE__" \
    "release_protection_observed=$([[ "$OLD_SERVING" -eq 1 ]] && printf '%s' '__TRUE__' || printf '%s' '__FALSE__')" \
    "business_impact_expected=__FALSE__" \
    "pod_list_excerpt=${POD_LIST:-__NULL__}" \
    "crash_log_excerpt=${CRASH_LOGS:-__NULL__}" \
    "health_observed_utc=${HEALTH_OBSERVED_UTC}" \
    "evidence_command=kubectl -n demo get pods -l ${LABEL_SELECTOR}; kubectl -n demo logs ${NEWEST_POD:-<pod>} --tail=30" \
    "note=maxUnavailable=0 旧 Pod 仍服务；这不是业务完全不可用"

  sleep 5
else
  if ! wait_for_rollout "$ROLLOUT_TIMEOUT"; then
    die "rollout 未完成；不宣称故障已完全生效，将执行受控恢复"
  fi
  if ! wait_for_health 60; then
    die "rollout 后 health/readiness 未恢复；将执行受控恢复"
  fi
  HEALTH_OBSERVED_UTC="$(utc_now)"
  jsonl "$LOG_FILE" \
    "event=rollout_observed" \
    "drill_id=${DRILL_ID}" \
    "fault_type=${FAULT}" \
    "fault_fully_effective=__TRUE__" \
    "health_observed_utc=${HEALTH_OBSERVED_UTC}" \
    "evidence_command=kubectl -n demo rollout status deployment/demo"
  sleep "$ALERT_WAIT"
fi

query_alert_receiver
jsonl "$LOG_FILE" \
  "event=alert_observation" \
  "drill_id=${DRILL_ID}" \
  "fault_type=${FAULT}" \
  "alert_fired=${ALERT_FIRED}" \
  "alert_http_status=${ALERT_HTTP}" \
  "alert_query=${ALERT_QUERY}" \
  "alert_evidence=${ALERT_EVIDENCE:-__NULL__}" \
  "root_cause_confirmed=__FALSE__" \
  "root_cause_evidence=__NULL__" \
  "note=alert_fired 为 null 表示未配置/未查询到/无法解析，不是“未告警”的推断"

COMPLETED=1
echo "演练故障已注入: drill_id=${DRILL_ID} fault=${FAULT} deployment=${DEPLOYMENT}" >&2
echo "状态文件（本地，gitignore）: ${STATE_FILE}" >&2
echo "恢复命令: scripts/drills/recover.sh --state '${STATE_FILE}'" >&2
[[ "$FAULT" == "startup-failure" ]] && echo "注意: 旧 Pod 仍服务，startup-failure 只验证发布保护，不制造业务不可用。" >&2
exit 0
