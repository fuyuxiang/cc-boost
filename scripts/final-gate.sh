#!/usr/bin/env bash
# Stop hook (final gate). Runs once when Claude is about to finish a turn.
#
# Strategy:
#   1. If no edits happened this turn, exit 0 (silent).
#   2. Run Layer A (deterministic agent-check). On failure, block stop and
#      inject the structured failure summary so Claude must repair.
#   3. On Layer A pass:
#        a. Classify the working-tree diff. If trivial, allow stop.
#        b. Look up diff_hash in the verifier cache. If a prior pass exists,
#           allow stop (we already verified this exact diff this session).
#        c. Otherwise, invoke run-verifier.sh to call the cross-family
#           verifier model directly. Record the verdict.
#        d. verdict = pass     -> cache + allow stop
#           verdict = fail     -> block stop with reasoning
#           verdict = uncertain -> behavior controlled by
#                                  config.verifier.uncertain_action
#                                  ("allow" default, or "block")
#           verdict = error    -> allow stop, surface a system message so
#                                 the user knows verifier wasn't reached
#
# Loop-protection (Layer A):
#   Track consecutive Stop-blocks in state. After CC_BOOST_MAX_BLOCKS
#   (default 3) we let Claude stop anyway and surface a warning.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"
# shellcheck source=/dev/null
source "$LIB_DIR/common.sh"

cat >/dev/null  # consume stdin

if ! cc_enabled; then exit 0; fi

PROJECT_DIR="$(cc_project_dir)"
AGENT_CHECK="$(cc_agent_check)"
STATE_DIR="$(cc_state_dir)"

# Did edits happen this turn? Use last-verify presence as a proxy.
LAST_VERIFY="$STATE_DIR/last-verify"
if [[ ! -f "$LAST_VERIFY" ]]; then exit 0; fi
NOW="$(date +%s)"
LAST="$(cat "$LAST_VERIFY" 2>/dev/null || echo 0)"
if (( NOW - LAST > 600 )); then exit 0; fi   # > 10 min idle

if [[ ! -x "$AGENT_CHECK" ]]; then exit 0; fi

# --- Layer A ---
MAX_BLOCKS="$(cc_cfg final_gate.max_blocks 3)"
BLOCKS_FILE="$STATE_DIR/stop-blocks"
BLOCKS=$(cat "$BLOCKS_FILE" 2>/dev/null || echo 0)

LOG_FILE="$STATE_DIR/final-check.log"
cc_run_agent_check "$LOG_FILE"
RC=$?

if (( RC != 0 )); then
  CLASSIFICATION_JSON="$("$SCRIPT_DIR/classify-failure.sh" "$LOG_FILE")"
  STATUS="$(echo "$CLASSIFICATION_JSON" | jq -r '.status // "regression"')"
  SUMMARY_JSON="$(echo "$CLASSIFICATION_JSON" | jq -c '.summary // {}')"
  TS="$(date -u +%FT%TZ)"

  if [[ "$STATUS" == "baseline" ]]; then
    LEDGER_LINE="$(jq -n \
      --arg ts "$TS" \
      --arg phase "final-gate" \
      --arg status "$STATUS" \
      --argjson classified "$CLASSIFICATION_JSON" \
      --arg model "${CC_BOOST_EXECUTOR_MODEL:-unknown}" \
      '{ts:$ts, phase:$phase, status:$status, executor_model:$model,
        failure:($classified.summary // {}), classification:$classified}')"
    cc_append_jsonl "$(cc_failures_path)" "$LEDGER_LINE"
    rm -f "$BLOCKS_FILE" 2>/dev/null || true
    jq -n --arg msg "[cc-boost] Final gate saw only known baseline failures. Releasing stop; no new regression detected." \
      '{systemMessage:$msg, suppressOutput:true}'
    exit 0
  fi

  # Layer A failed — block stop unless we've hit max_blocks.
  BLOCKS=$((BLOCKS + 1))
  echo "$BLOCKS" > "$BLOCKS_FILE"

  if (( BLOCKS > MAX_BLOCKS )); then
    jq -n --arg msg "[cc-boost] Final gate failed $BLOCKS times in a row — releasing the stop. Investigate $LOG_FILE manually." \
      '{systemMessage:$msg, suppressOutput:false}'
    rm -f "$BLOCKS_FILE" 2>/dev/null || true
    exit 0
  fi

  LEDGER_LINE="$(jq -n \
    --arg ts "$TS" \
    --arg phase "final-gate" \
    --arg status "$STATUS" \
    --arg blocks "$BLOCKS" \
    --argjson classified "$CLASSIFICATION_JSON" \
    --arg model "${CC_BOOST_EXECUTOR_MODEL:-unknown}" \
    '{ts:$ts, phase:$phase, status:$status, stop_blocks:($blocks|tonumber),
      executor_model:$model, failure:($classified.summary // {}), classification:$classified}')"
  cc_append_jsonl "$(cc_failures_path)" "$LEDGER_LINE"

  REASON=$(cat <<EOF
[cc-boost] Final gate (Layer A): agent-check FAILED — cannot finalize.

Structured failure:
$SUMMARY_JSON

This is final-gate block #$BLOCKS of $MAX_BLOCKS allowed.
Repair the failure, then attempt to finalize again. If the same error keeps
returning, change approach instead of patching repeatedly.
EOF
)
  cc_emit_block_stop "$REASON"
  exit 0
fi

# Layer A passed — clear block counter.
rm -f "$BLOCKS_FILE" 2>/dev/null || true

# --- Layer B (only if enabled and a verifier role is configured) ---
VERIFIER_MODEL="$(cc_cfg verifier.model "${CC_BOOST_VERIFIER_MODEL:-}")"
if ! cc_verifier_enabled || [[ -z "$VERIFIER_MODEL" ]]; then
  exit 0
fi

# Classify the diff.
CLASSIFY_JSON="$("$SCRIPT_DIR/diff-classify.sh" 2>/dev/null || echo '{"trivial":true,"hash":""}')"
TRIVIAL="$(echo "$CLASSIFY_JSON" | jq -r 'if has("trivial") then .trivial else true end')"
DIFF_HASH="$(echo "$CLASSIFY_JSON" | jq -r '.hash // ""')"
DIFF_FILES="$(echo "$CLASSIFY_JSON" | jq -r '.files // 0')"
DIFF_LINES="$(echo "$CLASSIFY_JSON" | jq -r '.lines // 0')"

if [[ "$TRIVIAL" == "true" || -z "$DIFF_HASH" ]]; then
  exit 0
fi

# Verifier cache — skip if we've already passed this exact diff.
CACHE_FILE="$(cc_state_dir)/verifications.jsonl"
mkdir -p "$(dirname "$CACHE_FILE")" 2>/dev/null || true
TTL_DAYS="$(cc_cfg verifier.cache_ttl_days 7)"
if [[ -f "$CACHE_FILE" ]]; then
  CUTOFF=$(( NOW - TTL_DAYS * 86400 ))
  CACHED_VERDICT="$(jq -r --arg h "$DIFF_HASH" --argjson cutoff "$CUTOFF" \
    'select(.diff_hash==$h and .ts_epoch>=$cutoff) | .verdict' \
    "$CACHE_FILE" 2>/dev/null | tail -n1)"
  if [[ "$CACHED_VERDICT" == "pass" ]]; then
    exit 0
  fi
fi

# Build inputs for run-verifier.sh.
TASK_FILE="$STATE_DIR/last-prompt.txt"
DIFF_FILE="$STATE_DIR/final-diff.patch"
EVIDENCE_FILE="$(cc_review_packets_dir)/final-review-packet.json"
(
  cd "$PROJECT_DIR" || exit 0
  cc_git_diff_with_untracked HEAD "$DIFF_FILE"
)

if [[ ! -s "$DIFF_FILE" ]]; then
  exit 0  # nothing to verify
fi

"$SCRIPT_DIR/review-packet.sh" \
  --task-file="$TASK_FILE" \
  --diff-file="$DIFF_FILE" \
  > "$EVIDENCE_FILE" 2>/dev/null || true

# If no task description was captured, fall back to a placeholder so verifier
# still has something to ground its judgment on (it'll lean on the diff).
if [[ ! -s "$TASK_FILE" ]]; then
  echo "(no explicit task description captured; judge the diff for internal consistency and likely intent)" > "$TASK_FILE"
fi

VERDICT_JSON="$("$SCRIPT_DIR/run-verifier.sh" \
  --task-file="$TASK_FILE" \
  --diff-file="$DIFF_FILE" \
  --evidence-file="$EVIDENCE_FILE" \
  --layer-a-log="$LOG_FILE" 2>/dev/null)"
RVRC=$?

# Always log the verdict to the ledger for /cc-ledger and lesson compilation.
TS="$(date -u +%FT%TZ)"
TS_EPOCH="$NOW"
if [[ -n "$VERDICT_JSON" ]]; then
  LEDGER_LINE="$(jq -n \
    --arg ts "$TS" \
    --argjson ts_epoch "$TS_EPOCH" \
    --arg phase "verifier" \
    --arg model "${CC_BOOST_EXECUTOR_MODEL:-unknown}" \
    --arg diff_hash "$DIFF_HASH" \
    --argjson files "$DIFF_FILES" \
    --argjson lines "$DIFF_LINES" \
    --argjson verdict_obj "$VERDICT_JSON" \
    '{ts:$ts, ts_epoch:$ts_epoch, phase:$phase, executor_model:$model,
      diff_hash:$diff_hash, diff_files:$files, diff_lines:$lines,
      verdict:$verdict_obj}')"
  cc_append_jsonl "$(cc_failures_path)" "$LEDGER_LINE"

  # Cache pass results so a repeat Stop within TTL doesn't re-call the API.
  V="$(echo "$VERDICT_JSON" | jq -r '.verdict // "error"')"
  if [[ "$V" == "pass" ]]; then
    CACHE_LINE="$(jq -n \
      --arg ts "$TS" --argjson ts_epoch "$TS_EPOCH" \
      --arg diff_hash "$DIFF_HASH" --arg verdict "pass" \
      '{ts:$ts, ts_epoch:$ts_epoch, diff_hash:$diff_hash, verdict:$verdict}')"
    cc_append_jsonl "$CACHE_FILE" "$CACHE_LINE"
  fi
fi

# Branch on exit code from run-verifier.sh.
case "$RVRC" in
  0)
    # pass or skipped — release stop.
    exit 0
    ;;
  1)
    # fail — block stop with the verifier's reasoning.
    REASONING="$(echo "$VERDICT_JSON" | jq -r '.reasoning // ""')"
    MISSING="$(echo "$VERDICT_JSON" | jq -r '.missing // [] | join("\n  - ")')"
    REGRESSIONS="$(echo "$VERDICT_JSON" | jq -r '.regressions // [] | join("\n  - ")')"
    SMALLEST="$(echo "$VERDICT_JSON" | jq -r '.smallest_repair // ""')"
    V_MODEL="$(echo "$VERDICT_JSON" | jq -r '.verifier_model // "verifier"')"
    REASON=$(cat <<EOF
[cc-boost] Layer B (cross-model verifier: $V_MODEL) returned verdict=fail.

Reasoning: $REASONING

Missing:
  - ${MISSING:-(none)}

Regressions:
  - ${REGRESSIONS:-(none)}

Smallest repair: ${SMALLEST:-(unspecified)}

Repair the issue above, then attempt to finalize again.
EOF
)
    cc_emit_block_stop "$REASON"
    exit 0
    ;;
  2)
    # uncertain — config decides.
    UNCERTAIN_ACTION="$(cc_cfg verifier.uncertain_action allow)"
    if [[ "$UNCERTAIN_ACTION" == "block" ]]; then
      REASONING="$(echo "$VERDICT_JSON" | jq -r '.reasoning // ""')"
      V_MODEL="$(echo "$VERDICT_JSON" | jq -r '.verifier_model // "verifier"')"
      REASON=$(cat <<EOF
[cc-boost] Layer B (cross-model verifier: $V_MODEL) returned verdict=uncertain
and config.verifier.uncertain_action=block. Address the verifier's concern
or set uncertain_action=allow to release the gate.

Reasoning: $REASONING
EOF
)
      cc_emit_block_stop "$REASON"
      exit 0
    fi
    # default: allow but surface a system message
    jq -n --arg msg "[cc-boost] Verifier verdict=uncertain — releasing stop (config.verifier.uncertain_action=allow)." \
      '{systemMessage:$msg, suppressOutput:true}'
    exit 0
    ;;
  3 | *)
    # internal error — never block on verifier infrastructure failure.
    REASON_TXT="$(echo "$VERDICT_JSON" | jq -r '.reasoning // "verifier unavailable"' 2>/dev/null)"
    jq -n --arg msg "[cc-boost] Verifier could not run ($REASON_TXT). Releasing stop. Run /cc-doctor to inspect." \
      '{systemMessage:$msg, suppressOutput:false}'
    exit 0
    ;;
esac
