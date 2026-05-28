#!/usr/bin/env bash
# Compress raw build/test logs into a single structured failure record.
# Heuristic-only (no LLM) — runs locally, costs nothing, fires on every fail.
# Output: JSON object on stdout.
#
# Schema:
#   {
#     "type":   "ts_error|lint_error|test_failure|build_error|generic",
#     "tool":   "tsc|eslint|pytest|cargo|...",
#     "files":  ["src/x.ts:42"],
#     "summary":"Short one-line description",
#     "evidence":"...trimmed log fragment...",
#     "suggested_focus": "What the model should look at next"
#   }
set -uo pipefail

LOG_FILE="${1:-/dev/stdin}"
RAW="$(cat "$LOG_FILE" 2>/dev/null || true)"
[[ -z "$RAW" ]] && { echo '{"type":"generic","summary":"empty log","evidence":""}'; exit 0; }

# Truncate evidence to keep injection cheap.
trim() {
  local txt="$1"; local n="${2:-1500}"
  if [[ ${#txt} -gt $n ]]; then
    echo "${txt:0:$n}…[truncated]"
  else
    echo "$txt"
  fi
}

# Try classifiers in priority order. First hit wins.

# 1. TypeScript / tsc
ts_hits="$(echo "$RAW" | grep -E "error TS[0-9]+" | head -n 5)"
if [[ -n "$ts_hits" ]]; then
  files=$(echo "$ts_hits" | awk -F'(' '{print $1}' | awk '{$1=$1};1' | sort -u | head -n 5)
  summary=$(echo "$ts_hits" | head -n1)
  jq -n \
    --arg type "ts_error" \
    --arg tool "tsc" \
    --arg summary "$(trim "$summary" 200)" \
    --arg evidence "$(trim "$ts_hits" 1500)" \
    --arg focus "Fix the type errors above. Inspect the involved types/imports before re-emitting code." \
    --argjson files "$(echo "$files" | jq -R . | jq -s 'map(select(.!=""))')" \
    '{type:$type, tool:$tool, files:$files, summary:$summary, evidence:$evidence, suggested_focus:$focus}'
  exit 0
fi

# 2. ESLint
eslint_hits="$(echo "$RAW" | grep -E "(error|warning) +.*[a-z-]+/[a-z-]+$|^/.*\.(ts|tsx|js|jsx)" | head -n 10)"
if echo "$RAW" | grep -qE "ESLint|eslint"; then
  jq -n \
    --arg type "lint_error" \
    --arg tool "eslint" \
    --arg summary "$(trim "$(echo "$RAW" | grep -E '✖|problem' | head -n1)" 200)" \
    --arg evidence "$(trim "$eslint_hits" 1500)" \
    --arg focus "Resolve the eslint rules cited above. Do not disable rules unless the user asked." \
    '{type:$type, tool:$tool, summary:$summary, evidence:$evidence, suggested_focus:$focus}'
  exit 0
fi

# 3. Pytest
if echo "$RAW" | grep -qE "(FAILED|ERROR) .*::.*"; then
  pytest_hits="$(echo "$RAW" | grep -E "(FAILED|ERROR|assert |E +)" | head -n 25)"
  files=$(echo "$pytest_hits" | grep -oE '[a-zA-Z0-9_./-]+\.py(:[0-9]+)?' | sort -u | head -n 5)
  jq -n \
    --arg type "test_failure" \
    --arg tool "pytest" \
    --arg summary "$(trim "$(echo "$RAW" | grep -E 'short test summary|FAILED' | head -n1)" 200)" \
    --arg evidence "$(trim "$pytest_hits" 1500)" \
    --arg focus "Inspect the failing assertions. Update only what the failure indicates is wrong; do not refactor unrelated code." \
    --argjson files "$(echo "$files" | jq -R . | jq -s 'map(select(.!=""))')" \
    '{type:$type, tool:$tool, files:$files, summary:$summary, evidence:$evidence, suggested_focus:$focus}'
  exit 0
fi

# 4. Vitest / Jest
if echo "$RAW" | grep -qE "(FAIL|✖) .*\.(test|spec)\."; then
  vt_hits="$(echo "$RAW" | grep -E "(FAIL|Expected|Received|×|✖|at )" | head -n 25)"
  files=$(echo "$vt_hits" | grep -oE '[a-zA-Z0-9_./-]+\.(test|spec)\.(t|j)sx?(:[0-9]+)?' | sort -u | head -n 5)
  jq -n \
    --arg type "test_failure" \
    --arg tool "vitest_or_jest" \
    --arg summary "$(trim "$(echo "$RAW" | grep -E 'Tests: .*failed|FAIL' | head -n1)" 200)" \
    --arg evidence "$(trim "$vt_hits" 1500)" \
    --arg focus "Look at expected vs received. Fix the smallest delta that satisfies the assertion." \
    --argjson files "$(echo "$files" | jq -R . | jq -s 'map(select(.!=""))')" \
    '{type:$type, tool:$tool, files:$files, summary:$summary, evidence:$evidence, suggested_focus:$focus}'
  exit 0
fi

# 5. Cargo
if echo "$RAW" | grep -qE "error\[E[0-9]+\]"; then
  cargo_hits="$(echo "$RAW" | grep -E "error\[E[0-9]+\]|^ +--> " | head -n 25)"
  files=$(echo "$cargo_hits" | grep -oE '[a-zA-Z0-9_./-]+\.rs(:[0-9]+)?' | sort -u | head -n 5)
  jq -n \
    --arg type "build_error" \
    --arg tool "cargo" \
    --arg summary "$(trim "$(echo "$RAW" | grep -E 'error\[E' | head -n1)" 200)" \
    --arg evidence "$(trim "$cargo_hits" 1500)" \
    --arg focus "Fix the rustc/clippy diagnostics above. Compiler suggestions are usually right." \
    --argjson files "$(echo "$files" | jq -R . | jq -s 'map(select(.!=""))')" \
    '{type:$type, tool:$tool, files:$files, summary:$summary, evidence:$evidence, suggested_focus:$focus}'
  exit 0
fi

# 6. Go test
if echo "$RAW" | grep -qE "^--- FAIL:"; then
  go_hits="$(echo "$RAW" | grep -E "FAIL|Error:|^ +.*\.go:" | head -n 25)"
  files=$(echo "$go_hits" | grep -oE '[a-zA-Z0-9_./-]+\.go(:[0-9]+)?' | sort -u | head -n 5)
  jq -n \
    --arg type "test_failure" \
    --arg tool "go_test" \
    --arg summary "$(trim "$(echo "$RAW" | grep -E '--- FAIL' | head -n1)" 200)" \
    --arg evidence "$(trim "$go_hits" 1500)" \
    --arg focus "Read the failing assertion and the file:line. Make the smallest change that passes." \
    --argjson files "$(echo "$files" | jq -R . | jq -s 'map(select(.!=""))')" \
    '{type:$type, tool:$tool, files:$files, summary:$summary, evidence:$evidence, suggested_focus:$focus}'
  exit 0
fi

# 7. Generic — pull the last 30 lines (where most tools put the error).
tail_evidence="$(echo "$RAW" | tail -n 30)"
jq -n \
  --arg type "generic" \
  --arg tool "unknown" \
  --arg summary "agent-check failed (uncategorized)" \
  --arg evidence "$(trim "$tail_evidence" 1500)" \
  --arg focus "Read the tail of the log; the error usually surfaces near the end." \
  '{type:$type, tool:$tool, summary:$summary, evidence:$evidence, suggested_focus:$focus}'
