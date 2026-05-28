#!/usr/bin/env bash
# Layer B verifier driver. Calls the configured verifier model directly via
# its provider HTTP endpoint and emits a verdict JSON on stdout.
#
# Why this script exists:
#   The cc-boost-verifier subagent (frontmatter `model: inherit`) runs on the
#   *current* Claude Code model — same family as the executor in most setups,
#   defeating the cross-family-decorrelation argument. This script bypasses
#   the subagent for the Stop-gate path and calls a different provider's API
#   directly so the verdict is genuinely cross-family.
#
# Usage:
#   run-verifier.sh \
#     --task-file <path>     (required; user's task description)
#     --diff-file <path>     (required; git diff to review)
#     --layer-a-log <path>   (optional; deterministic check log)
#
# Exit codes:
#   0 = pass | skipped       (caller should release Stop)
#   1 = fail                 (caller should block Stop)
#   2 = uncertain            (caller decides per config.verifier.uncertain_action)
#   3 = internal error       (caller should release Stop, log warning)
#
# stdout is always a single-line JSON object — callers parse it for ledger
# entries and cache writes.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"
# shellcheck source=/dev/null
source "$LIB_DIR/common.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/registry.sh"

emit_skip() {
  jq -n --arg reason "$1" \
    '{verdict:"skipped", score:null, missing:[], regressions:[], test_quality:"absent", smallest_repair:"", reasoning:$reason}'
  exit 0
}
emit_uncertain() {
  jq -n --arg reason "$1" \
    '{verdict:"uncertain", score:null, missing:[], regressions:[], test_quality:"absent", smallest_repair:"", reasoning:$reason}'
  exit 2
}
emit_internal() {
  jq -n --arg reason "$1" \
    '{verdict:"error", score:null, missing:[], regressions:[], test_quality:"absent", smallest_repair:"", reasoning:$reason}'
  exit 3
}

TASK_FILE=""
DIFF_FILE=""
LAYER_A_LOG=""
for arg in "$@"; do
  case "$arg" in
    --task-file=*)   TASK_FILE="${arg#--task-file=}" ;;
    --diff-file=*)   DIFF_FILE="${arg#--diff-file=}" ;;
    --layer-a-log=*) LAYER_A_LOG="${arg#--layer-a-log=}" ;;
  esac
done

[[ -n "$TASK_FILE" && -f "$TASK_FILE" ]] || emit_skip "no task description provided"
[[ -n "$DIFF_FILE" && -f "$DIFF_FILE" && -s "$DIFF_FILE" ]] || emit_skip "empty diff"

CFG="$(cc_config_path)"
[[ -f "$CFG" ]] || emit_skip "no config — run /cc-init"

if ! command -v jq >/dev/null 2>&1; then emit_internal "jq missing"; fi
if ! command -v curl >/dev/null 2>&1; then emit_internal "curl missing"; fi

# Pull verifier role from config.
ENABLED="$(jq -r '.verifier.enabled // false' "$CFG" 2>/dev/null)"
[[ "$ENABLED" == "true" ]] || emit_skip "verifier.enabled is false"

V_PROVIDER="$(jq -r '.verifier.provider // ""' "$CFG" 2>/dev/null)"
V_MODEL="$(jq -r '.verifier.model // ""' "$CFG" 2>/dev/null)"
V_FAMILY="$(jq -r '.verifier.family // ""' "$CFG" 2>/dev/null)"
EXEC_FAMILY="$(jq -r '.executor.family // ""' "$CFG" 2>/dev/null)"
[[ -n "$V_PROVIDER" && -n "$V_MODEL" ]] || emit_skip "no verifier configured"

ENDPOINT="$(cc_provider_endpoint "$V_PROVIDER" || true)"
[[ -n "$ENDPOINT" ]] || emit_internal "unknown provider: $V_PROVIDER"
IFS='|' read -r PROTOCOL BASE_URL ENV_VAR <<< "$ENDPOINT"

API_KEY="${!ENV_VAR:-}"
[[ -n "$API_KEY" ]] || emit_skip "$ENV_VAR not set"

# Trim oversized inputs so we don't blow the verifier's context budget.
trim_to() {
  local f="$1"; local n="$2"
  if [[ ! -f "$f" ]]; then echo ""; return; fi
  local size; size=$(wc -c < "$f" | tr -d ' ')
  if (( size <= n )); then cat "$f"; return; fi
  head -c "$((n / 2))" "$f"
  printf '\n…[truncated middle, %d bytes total]…\n' "$size"
  tail -c "$((n / 2))" "$f"
}

TASK_TXT="$(trim_to "$TASK_FILE" 4000)"
DIFF_TXT="$(trim_to "$DIFF_FILE" 12000)"
LAYER_A_TXT=""
[[ -n "$LAYER_A_LOG" && -f "$LAYER_A_LOG" ]] && LAYER_A_TXT="$(trim_to "$LAYER_A_LOG" 2000)"

SYSTEM_PROMPT='You are the cc-boost cross-model verifier (Layer B). You read a task, a diff, and a deterministic-check log, then judge whether the diff actually solves the task. You do not modify code.

Output: a single JSON object — no prose, no code fences. Schema:
{"verdict":"pass"|"fail"|"uncertain","score":0.0-1.0,"missing":[],"regressions":[],"test_quality":"good"|"weak"|"absent","smallest_repair":"","reasoning":""}

Rules:
- pass = intent satisfied, no spotted regressions, tests genuinely exercise the change.
- fail = missing[] or regressions[] is non-empty AND concrete (name a file or behavior).
- uncertain = you genuinely cannot tell from the diff alone. Do not default to uncertain to be safe.
- reasoning: 2-4 sentences.
- Emit JSON only.'

USER_PROMPT="$(jq -n \
  --arg task "$TASK_TXT" \
  --arg diff "$DIFF_TXT" \
  --arg log "$LAYER_A_TXT" \
  '"## Task\n\n" + $task + "\n\n## Diff (git diff HEAD)\n\n```diff\n" + $diff + "\n```\n\n## Layer A check log\n\n```\n" + (if $log == "" then "(none)" else $log end) + "\n```\n\nReturn only the verdict JSON."' \
  -r 2>/dev/null)"

[[ -n "$USER_PROMPT" ]] || emit_internal "failed to build user prompt"

STATE_DIR="$(cc_state_dir)"
RESP_FILE="$STATE_DIR/last-verifier-response.json"
ERR_FILE="$STATE_DIR/last-verifier-error.log"
: > "$ERR_FILE"

case "$PROTOCOL" in
  openai_chat)
    REQ_BODY="$(jq -n \
      --arg model "$V_MODEL" \
      --arg sys "$SYSTEM_PROMPT" \
      --arg usr "$USER_PROMPT" \
      '{model:$model, temperature:0.1, messages:[{role:"system",content:$sys},{role:"user",content:$usr}]}')"
    HTTP_CODE="$(curl -sS -o "$RESP_FILE" -w '%{http_code}' \
      -X POST "$BASE_URL/chat/completions" \
      -H "Authorization: Bearer $API_KEY" \
      -H 'Content-Type: application/json' \
      --max-time 90 \
      --data-binary "$REQ_BODY" 2>>"$ERR_FILE" || echo "000")"
    ;;
  anthropic_messages)
    REQ_BODY="$(jq -n \
      --arg model "$V_MODEL" \
      --arg sys "$SYSTEM_PROMPT" \
      --arg usr "$USER_PROMPT" \
      '{model:$model, max_tokens:1024, system:$sys, messages:[{role:"user",content:$usr}]}')"
    HTTP_CODE="$(curl -sS -o "$RESP_FILE" -w '%{http_code}' \
      -X POST "$BASE_URL/messages" \
      -H "x-api-key: $API_KEY" \
      -H 'anthropic-version: 2023-06-01' \
      -H 'Content-Type: application/json' \
      --max-time 90 \
      --data-binary "$REQ_BODY" 2>>"$ERR_FILE" || echo "000")"
    ;;
  *)
    emit_internal "unknown protocol: $PROTOCOL"
    ;;
esac

if [[ "$HTTP_CODE" != "200" ]]; then
  emit_uncertain "verifier HTTP $HTTP_CODE — see $ERR_FILE"
fi

# Extract assistant text per protocol.
case "$PROTOCOL" in
  openai_chat)
    RAW="$(jq -r '.choices[0].message.content // empty' "$RESP_FILE" 2>/dev/null)"
    ;;
  anthropic_messages)
    RAW="$(jq -r '[.content[]? | select(.type=="text") | .text] | join("\n")' "$RESP_FILE" 2>/dev/null)"
    ;;
esac

[[ -n "$RAW" ]] || emit_uncertain "empty verifier response"

# Try direct JSON parse; if that fails, strip ``` fences and try again.
parse_verdict() {
  local s="$1"
  if echo "$s" | jq -e . >/dev/null 2>&1; then echo "$s"; return 0; fi
  # Strip first/last fence pair.
  local stripped
  stripped="$(echo "$s" | sed -n '/```/,$p' | sed '1d' | sed -n '/```/q;p')"
  if [[ -n "$stripped" ]] && echo "$stripped" | jq -e . >/dev/null 2>&1; then
    echo "$stripped"; return 0
  fi
  return 1
}

VERDICT_JSON="$(parse_verdict "$RAW" || true)"
[[ -n "$VERDICT_JSON" ]] || emit_uncertain "verifier returned non-JSON"

# Normalize fields with sane defaults; ensure verdict is one of the allowed values.
NORMALIZED="$(echo "$VERDICT_JSON" | jq -c '
  {
    verdict: ((.verdict // "uncertain") | ascii_downcase
              | if (. == "pass" or . == "fail" or . == "uncertain") then . else "uncertain" end),
    score: (.score // null),
    missing: (.missing // []),
    regressions: (.regressions // []),
    test_quality: (.test_quality // "absent"),
    smallest_repair: (.smallest_repair // ""),
    reasoning: (.reasoning // "")
  }' 2>/dev/null || true)"

[[ -n "$NORMALIZED" ]] || emit_uncertain "verifier JSON missing required fields"

VERDICT="$(echo "$NORMALIZED" | jq -r '.verdict')"

# Annotate with metadata callers may want.
echo "$NORMALIZED" | jq -c \
  --arg model "$V_MODEL" \
  --arg provider "$V_PROVIDER" \
  --arg family "$V_FAMILY" \
  --arg exec_family "$EXEC_FAMILY" \
  '. + {verifier_model:$model, verifier_provider:$provider, cross_family:($family != $exec_family and $exec_family != "" and $family != "")}'

case "$VERDICT" in
  pass)      exit 0 ;;
  fail)      exit 1 ;;
  uncertain) exit 2 ;;
  *)         exit 2 ;;
esac
