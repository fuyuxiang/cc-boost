#!/usr/bin/env bash
# PostToolUse hook fired after Edit/Write/MultiEdit/NotebookEdit.
#
# Strategy (Layer A of the verifier-gated harness):
#   1. Skip fast if cc-boost is disabled or no agent-check.sh exists.
#   2. Run scripts/agent-check.sh from the project root.
#   3. On failure: summarize the log into a structured failure record,
#      append it to .cc-boost/failures.jsonl, and inject the structured
#      summary back into Claude as additionalContext so it can repair.
#   4. On success: stay silent (zero-noise path).
#
# Layer B (cross-model semantic verifier) is *not* run on every edit — only
# on Stop / explicit /cc-task. Running an LLM verifier on every keystroke
# would be wasteful.
set -uo pipefail

# Source the common library; fall back to inline defs if missing.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"
# shellcheck source=/dev/null
source "$LIB_DIR/common.sh"

# Read & discard the hook stdin (we don't need tool_input here, but bash hooks
# can hang if we don't consume stdin on some platforms).
HOOK_INPUT="$(cat || true)"

if ! cc_enabled; then exit 0; fi

PROJECT_DIR="$(cc_project_dir)"
AGENT_CHECK="$(cc_agent_check)"

# If user hasn't run /cc-init, just bail silently — don't block anything.
if [[ ! -x "$AGENT_CHECK" ]]; then
  exit 0
fi

# Throttle: don't run more often than every N seconds. Burst edits are common.
THROTTLE_SEC="$(cc_cfg verify.throttle_seconds 8)"
STATE_DIR="$(cc_state_dir)"
LAST_RUN_FILE="$STATE_DIR/last-verify"
NOW="$(date +%s)"
if [[ -f "$LAST_RUN_FILE" ]]; then
  LAST="$(cat "$LAST_RUN_FILE" 2>/dev/null || echo 0)"
  if (( NOW - LAST < THROTTLE_SEC )); then
    exit 0
  fi
fi
echo "$NOW" > "$LAST_RUN_FILE"

# Run agent-check.
LOG_FILE="$STATE_DIR/last-check.log"
cc_run_agent_check "$LOG_FILE"
RC=$?

if (( RC == 0 )); then
  # Success — clear consecutive-failure counter.
  rm -f "$STATE_DIR/consec-fails" 2>/dev/null || true
  cc_log INFO "agent-check passed"
  exit 0
fi

# Failure path.
CONSEC_FILE="$STATE_DIR/consec-fails"
CONSEC=$(( $(cat "$CONSEC_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$CONSEC" > "$CONSEC_FILE"

SUMMARY_JSON="$("$SCRIPT_DIR/summarize-failure.sh" "$LOG_FILE")"

# Persist into the failure ledger.
TS="$(date -u +%FT%TZ)"
LEDGER_LINE="$(jq -n \
  --arg ts "$TS" \
  --arg phase "post-edit" \
  --arg consec "$CONSEC" \
  --argjson failure "$SUMMARY_JSON" \
  --arg model "${CC_BOOST_EXECUTOR_MODEL:-unknown}" \
  '{ts:$ts, phase:$phase, consecutive:($consec|tonumber), executor_model:$model, failure:$failure}')"
cc_append_jsonl "$(cc_failures_path)" "$LEDGER_LINE"

# Build a Claude-facing context block. Keep it short and actionable.
read -r -d '' CONTEXT <<EOF || true
[cc-boost] agent-check FAILED after this edit (consecutive failure #$CONSEC).

Structured failure:
$SUMMARY_JSON

What to do next:
1. Read only the file(s) cited in the failure summary.
2. Make the smallest patch that addresses the cited issue.
3. Do NOT refactor unrelated code or introduce new dependencies.
4. After your fix, the next edit will trigger this verifier again.

If you have already tried and the same error keeps appearing twice in a row,
step back and reconsider the approach rather than patching incrementally.
EOF

# Emit the JSON envelope. PostToolUse supports additionalContext via hookSpecificOutput.
cc_emit_context PostToolUse "$CONTEXT"
exit 0
