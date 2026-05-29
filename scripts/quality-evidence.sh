#!/usr/bin/env bash
# Collect deterministic evidence about the current diff for quality review.
# This script intentionally stays heuristic-only: it gives the verifier and
# selector grounded signals without asking a model to infer repo state blindly.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"
# shellcheck source=/dev/null
source "$LIB_DIR/common.sh"

BASE_REF="HEAD"
for arg in "$@"; do
  case "$arg" in
    --base=*) BASE_REF="${arg#--base=}" ;;
  esac
done

PROJECT_DIR="$(cc_project_dir)"
cd "$PROJECT_DIR" 2>/dev/null || {
  jq -n '{schema_version:1, risk:"unknown", reasons:["no project dir"], changed_files:[], diff_files:0, diff_lines:0, quality_score:0}'
  exit 0
}

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  jq -n '{schema_version:1, risk:"unknown", reasons:["not a git repo"], changed_files:[], diff_files:0, diff_lines:0, quality_score:0}'
  exit 0
fi

NAME_STATUS="$(git diff --name-status "$BASE_REF" 2>/dev/null || true)"
STAT="$(git diff --numstat "$BASE_REF" 2>/dev/null || true)"
DIFF_NAME_ONLY="$(git diff --name-only "$BASE_REF" 2>/dev/null || true)"
UNTRACKED_LIST="$(git ls-files --others --exclude-standard 2>/dev/null | grep -vE '^\.cc-boost(/|$)' || true)"
ALL_NAMES="$(printf '%s\n%s\n' "$DIFF_NAME_ONLY" "$UNTRACKED_LIST" | sort -u)"

CHANGED_JSON="$(printf '%s\n' "$ALL_NAMES" | jq -R . | jq -s 'map(select(.!=""))')"

FILES=0; LINES=0; ADDED=0; REMOVED=0
while IFS=$'\t' read -r add rem _; do
  [[ -z "$add" ]] && continue
  FILES=$((FILES + 1))
  [[ "$add" == "-" ]] && add=0
  [[ "$rem" == "-" ]] && rem=0
  ADDED=$((ADDED + add))
  REMOVED=$((REMOVED + rem))
  LINES=$((LINES + add + rem))
done <<< "$STAT"

while IFS= read -r path; do
  [[ -z "$path" ]] && continue
  FILES=$((FILES + 1))
  file_lines=0
  if [[ -f "$path" ]]; then
    file_lines="$(wc -l < "$path" 2>/dev/null | tr -d ' ' || echo 0)"
  fi
  ADDED=$((ADDED + file_lines))
  LINES=$((LINES + file_lines))
done <<< "$UNTRACKED_LIST"

REASONS='[]'
add_reason() {
  local reason="$1"
  REASONS="$(echo "$REASONS" | jq --arg r "$reason" '. + [$r]')"
}

contains_path() {
  local pattern="$1"
  printf '%s\n' "$ALL_NAMES" | grep -E "$pattern" >/dev/null 2>&1
}

TESTS_CHANGED=false
LOCK_OR_DEP=false
GENERATED=false
PUBLIC_API=false
SECURITY=false
DELETE_OR_RENAME=false

if contains_path '(^|/)(test|tests|spec|__tests__)(/|$)|\.(test|spec)\.(js|jsx|ts|tsx|py)$|_test\.go$'; then
  TESTS_CHANGED=true
fi
if contains_path '(^|/)(package\.json|pnpm-lock\.yaml|package-lock\.json|yarn\.lock|bun\.lockb|pyproject\.toml|requirements.*\.txt|go\.mod|go\.sum|Cargo\.toml|Cargo\.lock)$'; then
  LOCK_OR_DEP=true
  add_reason "dependency-or-lockfile changed"
fi
if contains_path '(^|/)(dist|build|coverage|generated|gen)(/|$)|(\.min\.js$|\.pb\.go$|_pb2\.py$)'; then
  GENERATED=true
  add_reason "generated/build artifact touched"
fi
if contains_path '(^|/)(api|routes|controllers|schema|schemas|proto|types|interfaces|public)(/|$)|\.(d\.ts|proto|graphql|openapi\.ya?ml)$'; then
  PUBLIC_API=true
  add_reason "public api or schema surface touched"
fi
if contains_path '(^|/)(auth|security|permission|permissions|crypto|token|session|login|payment|billing|migration|migrations|db|database)(/|$)|(^|/)(Dockerfile|docker-compose\.ya?ml|\.github/workflows/)'; then
  SECURITY=true
  add_reason "security/data/infra sensitive path touched"
fi
if printf '%s\n' "$NAME_STATUS" | grep -E '^(D|R)' >/dev/null 2>&1; then
  DELETE_OR_RENAME=true
  add_reason "delete or rename detected"
fi
if (( FILES >= 3 )); then add_reason "diff touches $FILES files"; fi
if (( LINES >= 80 )); then add_reason "diff changes $LINES lines"; fi

RISK="low"
if [[ "$SECURITY" == true || "$LOCK_OR_DEP" == true || "$DELETE_OR_RENAME" == true ]] || (( FILES >= 5 || LINES >= 160 )); then
  RISK="high"
elif [[ "$PUBLIC_API" == true || "$GENERATED" == true ]] || (( FILES >= 3 || LINES >= 80 )); then
  RISK="medium"
fi

SCORE=100
case "$RISK" in
  high) SCORE=$((SCORE - 30)) ;;
  medium) SCORE=$((SCORE - 12)) ;;
esac
[[ "$LOCK_OR_DEP" == true ]] && SCORE=$((SCORE - 10))
[[ "$GENERATED" == true ]] && SCORE=$((SCORE - 8))
[[ "$PUBLIC_API" == true ]] && SCORE=$((SCORE - 8))
[[ "$SECURITY" == true ]] && SCORE=$((SCORE - 12))
[[ "$DELETE_OR_RENAME" == true ]] && SCORE=$((SCORE - 12))
if (( LINES > 0 && LINES <= 80 )); then SCORE=$((SCORE + 4)); fi
if [[ "$TESTS_CHANGED" == true ]]; then SCORE=$((SCORE + 6)); fi
(( SCORE < 0 )) && SCORE=0
(( SCORE > 100 )) && SCORE=100

jq -n \
  --arg risk "$RISK" \
  --argjson reasons "$REASONS" \
  --argjson changed "$CHANGED_JSON" \
  --argjson files "$FILES" \
  --argjson lines "$LINES" \
  --argjson added "$ADDED" \
  --argjson removed "$REMOVED" \
  --arg tests "$TESTS_CHANGED" \
  --arg dep "$LOCK_OR_DEP" \
  --arg gen "$GENERATED" \
  --arg api "$PUBLIC_API" \
  --arg sec "$SECURITY" \
  --arg del "$DELETE_OR_RENAME" \
  --argjson score "$SCORE" \
  '{schema_version:1, risk:$risk, reasons:$reasons,
    changed_files:$changed, diff_files:$files, diff_lines:$lines,
    added_lines:$added, removed_lines:$removed,
    tests_changed:($tests=="true"),
    dependency_or_lockfile_changed:($dep=="true"),
    generated_or_build_artifact_changed:($gen=="true"),
    public_api_or_schema_changed:($api=="true"),
    sensitive_path_changed:($sec=="true"),
    delete_or_rename:($del=="true"),
    quality_score:$score}'
