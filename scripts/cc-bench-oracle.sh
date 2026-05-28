#!/usr/bin/env bash
# Deterministic per-task oracle check used by /cc-bench. Reads oracle.json
# (must_pass + max_diff_lines) from the task dir and reports a structured
# verdict on stdout. Used by all three bench modes (bare/harness/bon) to
# decide if a task is solved.
#
# Usage:
#   cc-bench-oracle.sh --task-dir=<path> [--base-sha=<sha>]
#
# Output (stdout): JSON {solved, must_pass_results[], diff_lines, max_diff_lines, exceeded}
# Exit codes:
#   0 = solved (all must_pass commands exit 0 AND diff within budget)
#   1 = not solved
#   2 = bad invocation
set -uo pipefail

TASK_DIR=""
BASE_SHA=""
for arg in "$@"; do
  case "$arg" in
    --task-dir=*) TASK_DIR="${arg#--task-dir=}" ;;
    --base-sha=*) BASE_SHA="${arg#--base-sha=}" ;;
  esac
done

[[ -d "$TASK_DIR" ]] || { echo "cc-bench-oracle: --task-dir missing or not a dir" >&2; exit 2; }
ORACLE="$TASK_DIR/oracle.json"
[[ -f "$ORACLE" ]] || { echo "cc-bench-oracle: oracle.json not found in $TASK_DIR" >&2; exit 2; }

# must_pass commands.
MUST_PASS_JSON='[]'
ALL_OK=1
while IFS= read -r cmd; do
  [[ -z "$cmd" ]] && continue
  ( cd "$TASK_DIR" && bash -c "$cmd" ) > /tmp/cc-bench-cmd.log 2>&1
  RC=$?
  STATUS="pass"; (( RC == 0 )) || { STATUS="fail"; ALL_OK=0; }
  MUST_PASS_JSON="$(echo "$MUST_PASS_JSON" | jq \
    --arg cmd "$cmd" --arg status "$STATUS" --argjson rc "$RC" \
    '. + [{cmd:$cmd, status:$status, rc:$rc}]')"
done < <(jq -r '.must_pass[]?' "$ORACLE" 2>/dev/null)

MAX_DIFF_LINES="$(jq -r '.max_diff_lines // 0' "$ORACLE")"
DIFF_LINES=0
if [[ -n "$BASE_SHA" ]]; then
  STAT="$(cd "$TASK_DIR" && git diff "$BASE_SHA" -- . --numstat 2>/dev/null || true)"
  while IFS=$'\t' read -r added removed _; do
    [[ -z "$added" ]] && continue
    [[ "$added"   == "-" ]] && added=0
    [[ "$removed" == "-" ]] && removed=0
    DIFF_LINES=$((DIFF_LINES + added + removed))
  done <<< "$STAT"
fi

EXCEEDED="false"
if (( MAX_DIFF_LINES > 0 )) && (( DIFF_LINES > MAX_DIFF_LINES )); then
  EXCEEDED="true"
  ALL_OK=0
fi

SOLVED="false"; (( ALL_OK == 1 )) && SOLVED="true"

jq -n \
  --arg solved "$SOLVED" \
  --argjson must_pass "$MUST_PASS_JSON" \
  --argjson diff_lines "$DIFF_LINES" \
  --argjson max_diff_lines "$MAX_DIFF_LINES" \
  --arg exceeded "$EXCEEDED" \
  '{solved:($solved=="true"), must_pass_results:$must_pass, diff_lines:$diff_lines, max_diff_lines:$max_diff_lines, exceeded:($exceeded=="true")}'

(( ALL_OK == 1 )) && exit 0 || exit 1
