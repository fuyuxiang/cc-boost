#!/usr/bin/env bash
# Classify an agent-check failure as a new regression or a known baseline
# failure. Outputs one JSON object:
#   {status:"regression"|"baseline", fingerprint, baseline_match,
#    touches_changed, summary, changed_files}
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"
# shellcheck source=/dev/null
source "$LIB_DIR/common.sh"

LOG_FILE="${1:-}"
[[ -n "$LOG_FILE" && -f "$LOG_FILE" ]] || {
  jq -n '{status:"regression", reason:"missing log file"}'
  exit 0
}

SUMMARY_JSON="$("$SCRIPT_DIR/summarize-failure.sh" "$LOG_FILE")"
FINGERPRINT="$("$SCRIPT_DIR/failure-fingerprint.sh" "$SUMMARY_JSON")"
BASELINE_FILE="$(cc_baseline_path)"

BASELINE_MATCH="false"
if [[ -f "$BASELINE_FILE" ]] && command -v jq >/dev/null 2>&1; then
  if jq -e --arg fp "$FINGERPRINT" '(.fingerprints // []) | index($fp)' "$BASELINE_FILE" >/dev/null 2>&1; then
    BASELINE_MATCH="true"
  fi
fi

PROJECT_DIR="$(cc_project_dir)"
CHANGED_JSON='[]'
if git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  CHANGED_JSON="$(
    cd "$PROJECT_DIR" || exit 0
    { git diff --name-only HEAD 2>/dev/null || true; git ls-files --others --exclude-standard 2>/dev/null || true; } \
      | grep -vE '^\.cc-boost(/|$)' | sort -u | jq -R . | jq -s 'map(select(.!=""))'
  )"
fi

TOUCHES_CHANGED="$(
  jq -n \
    --argjson summary "$SUMMARY_JSON" \
    --argjson changed "$CHANGED_JSON" '
      def norm: tostring | sub(":[0-9]+$"; "");
      [($summary.files // [])[] | norm] as $failure_files
      | [($changed // [])[]] as $changed_files
      | if ($failure_files | length) == 0 then false
        else
          ([
            $failure_files[] as $f
            | $changed_files[] as $c
            | select(($c == $f) or ($c | startswith($f + "/")) or ($f | startswith($c + "/")))
          ] | length > 0)
        end
    ' 2>/dev/null
)"

STATUS="regression"
REGRESSION_ONLY="$(cc_cfg quality.regression_only true)"
if [[ "$REGRESSION_ONLY" == "true" && "$BASELINE_MATCH" == "true" && "$TOUCHES_CHANGED" != "true" ]]; then
  STATUS="baseline"
fi

jq -n \
  --arg status "$STATUS" \
  --arg fp "$FINGERPRINT" \
  --arg baseline "$BASELINE_MATCH" \
  --arg touches "$TOUCHES_CHANGED" \
  --argjson summary "$SUMMARY_JSON" \
  --argjson changed "$CHANGED_JSON" \
  '{status:$status, fingerprint:$fp, baseline_match:($baseline=="true"),
    touches_changed:($touches=="true"), summary:$summary, changed_files:$changed}'

exit 0
