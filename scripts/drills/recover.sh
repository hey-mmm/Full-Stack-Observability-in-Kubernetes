#!/usr/bin/env bash
# 恢复 demo 演练：优先按 .state JSON 恢复原 Deployment env，再恢复 Argo Application
# 的 auto-sync（仅 demo），最后等待 rollout 与 /healthz、/readyz。任何失败非 0。
# 若 state 丢失但显式 --force-normal，则把三个故障 env 全设为正常值并记录。
set -u -o pipefail

DRILLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${DRILLS_DIR}/lib.sh"

STATE_FILE=""
FORCE_NORMAL=0
QUIET=0

usage() {
  cat <<'EOF'
用法: scripts/drills/recover.sh [选项]

选项:
  --state PATH       指定 inject.sh 生成的 .state/<drill-id>.json
  --drill-id ID      按 drill_id 查找状态文件
  --force-normal     状态文件缺失时，仅将三个 DEMO_* env 设为正常值
  --quiet            减少 stdout
  -h, --help

恢复顺序：Deployment env -> rollout/health -> 恢复 Argo Application demo auto-sync。
只触碰 namespace=demo 的 deployment/demo 与 argocd/application/demo。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --state) STATE_FILE="${2:?--state 需要参数}"; shift 2 ;;
    --drill-id) STATE_FILE="${STATE_DIR}/${2:?--drill-id 需要参数}.json"; shift 2 ;;
    --force-normal) FORCE_NORMAL=1; shift ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage >&2; exit 2 ;;
  esac
done

require_cmds kubectl curl python3 timeout
ensure_dirs

if [[ -z "$STATE_FILE" ]]; then
  if [[ -f "${STATE_DIR}/latest" ]]; then
    STATE_FILE="$(head -n 1 "${STATE_DIR}/latest")"
  fi
fi
if [[ -n "$STATE_FILE" && ! -f "$STATE_FILE" ]]; then
  die "状态文件不存在: $STATE_FILE"
fi
if [[ -z "$STATE_FILE" && "$FORCE_NORMAL" -ne 1 ]]; then
  die "没有状态文件；如确认要全设正常值，请加 --force-normal"
fi

select_deployment
RECOVERY_STARTED_UTC="$(utc_now)"
DRILL_ID="manual-$(utc_now)"
SHOULD_RESTORE=0
APP_RESTORED=0
ENV_RESTORED=0
ROLLOUT_OK=0
HEALTH_OK=0
ROLLOUT_UTC="__NULL__"
HEALTH_UTC="__NULL__"
ENV_MODE="original-env"

if [[ -n "$STATE_FILE" ]]; then
  DRILL_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("drill_id","unknown"))' "$STATE_FILE")"
  python3 - "$STATE_FILE" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    state = json.load(fh)
assert state.get("namespace") == "demo", state.get("namespace")
assert state.get("deployment") == "demo", state.get("deployment")
assert state.get("application", "demo") == "demo"
PY
  SHOULD_RESTORE="$(python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print(1 if s.get("application_found") and s.get("auto_sync_was_enabled") else 0)' "$STATE_FILE")"

  ENV_PATCH="${STATE_DIR}/${DRILL_ID}-env-restore.json"
  python3 - "$STATE_FILE" "$ENV_PATCH" <<'PY'
import json, sys
state_path, patch_path = sys.argv[1:3]
with open(state_path, encoding="utf-8") as fh:
    state = json.load(fh)
idx = state["container_index"]
op = "replace" if state.get("env_present", True) else "add"
patch = [{
    "op": op,
    "path": f"/spec/template/spec/containers/{idx}/env",
    "value": state.get("original_env", []),
}]
with open(patch_path, "w", encoding="utf-8") as fh:
    json.dump(patch, fh, ensure_ascii=False)
PY

  if k -n "$NAMESPACE" patch "deployment/${DEPLOYMENT}" --type=json --patch-file="$ENV_PATCH" >/dev/null; then
    ENV_RESTORED=1
  else
    warn "按原 env 恢复失败，回退为三个 DEMO_* 全正常值"
    if k -n "$NAMESPACE" set env "deployment/${DEPLOYMENT}" \
        DEMO_ERROR_RATE=0 DEMO_LATENCY_MS=0 DEMO_STARTUP_FAIL=false >/dev/null; then
      ENV_RESTORED=1
      ENV_MODE="fallback-normal"
    fi
  fi
else
  # 没有 state 时只做明确声明的全正常值恢复。
  if k -n "$NAMESPACE" set env "deployment/${DEPLOYMENT}" \
      DEMO_ERROR_RATE=0 DEMO_LATENCY_MS=0 DEMO_STARTUP_FAIL=false >/dev/null; then
    ENV_RESTORED=1
    ENV_MODE="forced-normal-no-state"
  fi
fi

restore_application() {
  [[ "$SHOULD_RESTORE" -eq 1 ]] || return 0
  [[ -n "$STATE_FILE" ]] || return 1

  local app_json="${STATE_DIR}/${DRILL_ID}-application-after.json"
  local app_patch="${STATE_DIR}/${DRILL_ID}-app-restore.json"
  if ! k -n "$ARGO_NAMESPACE" get application "$ARGO_APPLICATION" -o json >"$app_json"; then
    warn "无法读取 Argo Application ${ARGO_NAMESPACE}/${ARGO_APPLICATION}"
    return 1
  fi
  python3 - "$STATE_FILE" "$app_json" "$app_patch" <<'PY'
import json, sys
state_path, app_path, patch_path = sys.argv[1:4]
with open(state_path, encoding="utf-8") as fh:
    state = json.load(fh)
original = state.get("original_automated")
with open(patch_path, "w", encoding="utf-8") as fh:
    json.dump({"spec": {"syncPolicy": {"automated": original}}}, fh, ensure_ascii=False)
PY
  if ! k -n "$ARGO_NAMESPACE" patch application "$ARGO_APPLICATION" --type=merge \
      --patch-file="$app_patch" >/dev/null; then
    warn "恢复 Argo Application auto-sync 失败"
    return 1
  fi
  # 验证确实恢复为保存的原值。
  if ! k -n "$ARGO_NAMESPACE" get application "$ARGO_APPLICATION" -o json >"$app_json"; then
    warn "无法验证 Argo Application auto-sync 恢复结果"
    return 1
  fi
  if python3 - "$STATE_FILE" "$app_json" <<'PY'
import json, sys
state = json.load(open(sys.argv[1], encoding="utf-8"))
app = json.load(open(sys.argv[2], encoding="utf-8"))
current = ((app.get("spec") or {}).get("syncPolicy") or {}).get("automated")
assert current == state.get("original_automated"), (current, state.get("original_automated"))
PY
  then
    APP_RESTORED=1
    return 0
  fi
  warn "Argo Application auto-sync 恢复后校验不一致"
  return 1
}

cleanup() {
  if [[ "$SHOULD_RESTORE" -eq 1 && "$APP_RESTORED" -eq 0 ]]; then
    warn "恢复流程退出前仍尝试恢复 demo Application auto-sync"
    restore_application || true
  fi
  stop_port_forward
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ "$ENV_RESTORED" -eq 1 ]]; then
  if wait_for_rollout "${DRILL_RECOVERY_ROLLOUT_TIMEOUT:-180s}"; then
    ROLLOUT_OK=1
    ROLLOUT_UTC="$(utc_now)"
  fi
fi

if ! start_port_forward; then
  warn "无法建立 port-forward；不能声明 health 成功"
elif wait_for_health "${DRILL_HEALTH_TIMEOUT:-60}"; then
  HEALTH_OK=1
  HEALTH_UTC="$(utc_now)"
fi

if [[ "$SHOULD_RESTORE" -eq 1 ]]; then
  restore_application || true
fi

STATUS="failed"
if [[ "$ENV_RESTORED" -eq 1 && "$ROLLOUT_OK" -eq 1 && "$HEALTH_OK" -eq 1 ]]; then
  if [[ "$SHOULD_RESTORE" -eq 0 || "$APP_RESTORED" -eq 1 ]]; then
    STATUS="success"
  fi
fi

jsonl "$LOG_FILE" \
  "event=recovered" \
  "drill_id=${DRILL_ID}" \
  "recovery_started_utc=${RECOVERY_STARTED_UTC}" \
  "rollout_completed_utc=${ROLLOUT_UTC}" \
  "health_ok_utc=${HEALTH_UTC}" \
  "env_restore_mode=${ENV_MODE}" \
  "gitops_restored=$([[ "$APP_RESTORED" -eq 1 ]] && printf '%s' '__TRUE__' || printf '%s' '__FALSE__')" \
  "recovered=$([[ "$STATUS" == "success" ]] && printf '%s' '__TRUE__' || printf '%s' '__FALSE__')" \
  "status=${STATUS}" \
  "root_cause_confirmed=__FALSE__" \
  "root_cause_evidence=__NULL__" \
  "evidence_command=kubectl -n demo rollout status deployment/demo; curl /healthz; curl /readyz"

if [[ "$QUIET" -ne 1 ]]; then
  echo "recover: drill_id=${DRILL_ID} env=${ENV_MODE} rollout=${ROLLOUT_OK} health=${HEALTH_OK} gitops_restored=${APP_RESTORED} status=${STATUS}"
fi
[[ "$STATUS" == "success" ]] || exit 1
exit 0
