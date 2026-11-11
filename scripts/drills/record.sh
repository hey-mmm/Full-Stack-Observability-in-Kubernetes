#!/usr/bin/env bash
# 由主代理/操作者手工记录根因确认或补充证据；默认不自动确认根因。
set -u -o pipefail

DRILLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${DRILLS_DIR}/lib.sh"

DRILL_ID=""
EVIDENCE=""
COMMAND=""
CONFIRMED=0

usage() {
  cat <<'EOF'
用法: scripts/drills/record.sh --drill-id ID --evidence "实际观测证据" [选项]

选项:
  --drill-id ID       演练 ID（inject.sh 输出）
  --evidence TEXT     实际观测到的命令输出/指标/日志证据
  --command TEXT      产生证据的命令
  --confirmed         明确确认根因（仅人工/主代理确认后使用）
  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --drill-id) DRILL_ID="${2:?--drill-id 需要参数}"; shift 2 ;;
    --evidence) EVIDENCE="${2:?--evidence 需要参数}"; shift 2 ;;
    --command) COMMAND="${2:?--command 需要参数}"; shift 2 ;;
    --confirmed) CONFIRMED=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$DRILL_ID" ]] || die "--drill-id 必填"
[[ -n "$EVIDENCE" ]] || die "--evidence 必填；没有实际证据不要确认根因"
[[ -f "${STATE_DIR}/${DRILL_ID}.json" ]] || warn "未找到 ${STATE_DIR}/${DRILL_ID}.json；仍追加人工事件"
ensure_dirs

if [[ "$CONFIRMED" -eq 1 ]]; then
  CONFIRMED_VALUE="__TRUE__"
else
  CONFIRMED_VALUE="__FALSE__"
fi

jsonl "$LOG_FILE" \
  "event=root_cause_confirmation" \
  "drill_id=${DRILL_ID}" \
  "root_cause_confirmed=${CONFIRMED_VALUE}" \
  "root_cause_evidence=${EVIDENCE}" \
  "observed_command=${COMMAND:-__NULL__}" \
  "recorded_by=${USER:-unknown}" \
  "note=仅人工/主代理确认后可置 --confirmed"

echo "已追加根因记录: ${LOG_FILE}" >&2
