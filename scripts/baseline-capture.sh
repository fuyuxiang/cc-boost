#!/usr/bin/env bash
# Capture the current project health as cc-boost's regression baseline.
#
# The baseline lets the harness distinguish "the repo was already red" from
# "this edit introduced a new failure". That keeps weak models from expanding
# a small task into unrelated cleanup while still blocking regressions.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"
# shellcheck source=/dev/null
source "$LIB_DIR/common.sh"

PROJECT_DIR="$(cc_project_dir)"
STATE_DIR="$(cc_state_dir)"
BASELINE_FILE="$(cc_baseline_path)"
LOG_FILE="$STATE_DIR/baseline-check.log"

mkdir -p "$(dirname "$BASELINE_FILE")" "$STATE_DIR" 2>/dev/null || true

AGENT_CHECK="$(cc_agent_check)"
TS="$(date -u +%FT%TZ)"

if [[ ! -x "$AGENT_CHECK" ]]; then
  jq -n \
    --arg ts "$TS" \
    --arg status "missing-check" \
    --arg reason ".cc-boost/agent-check.sh missing or not executable" \
    '{schema_version:1, captured_at:$ts, status:$status, fingerprints:[], reason:$reason}' \
    > "$BASELINE_FILE"
  cat "$BASELINE_FILE"
  exit 0
fi

cc_run_agent_check "$LOG_FILE"
RC=$?

if (( RC == 0 )); then
  jq -n \
    --arg ts "$TS" \
    --arg log "$LOG_FILE" \
    '{schema_version:1, captured_at:$ts, status:"pass", fingerprints:[], log_file:$log}' \
    > "$BASELINE_FILE"
  cat "$BASELINE_FILE"
  exit 0
fi

SUMMARY_JSON="$("$SCRIPT_DIR/summarize-failure.sh" "$LOG_FILE")"
FINGERPRINT="$("$SCRIPT_DIR/failure-fingerprint.sh" "$SUMMARY_JSON")"

jq -n \
  --arg ts "$TS" \
  --arg log "$LOG_FILE" \
  --arg fp "$FINGERPRINT" \
  --argjson summary "$SUMMARY_JSON" \
  '{schema_version:1, captured_at:$ts, status:"fail", fingerprints:[$fp], first_failure:$summary, log_file:$log}' \
  > "$BASELINE_FILE"

cat "$BASELINE_FILE"
exit 0
