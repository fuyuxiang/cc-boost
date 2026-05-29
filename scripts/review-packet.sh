#!/usr/bin/env bash
# Build a compact, deterministic review packet for verifier models.
# The packet is still read-only evidence: it never asks the verifier to edit.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"
# shellcheck source=/dev/null
source "$LIB_DIR/common.sh"

BASE_REF="HEAD"
TASK_FILE=""
DIFF_FILE=""
for arg in "$@"; do
  case "$arg" in
    --base=*) BASE_REF="${arg#--base=}" ;;
    --task-file=*) TASK_FILE="${arg#--task-file=}" ;;
    --diff-file=*) DIFF_FILE="${arg#--diff-file=}" ;;
  esac
done

PROJECT_DIR="$(cc_project_dir)"
cd "$PROJECT_DIR" 2>/dev/null || {
  jq -n '{schema_version:1, risk:"unknown", reasons:["no project dir"], quality:{}, related_tests:[], callsite_hints:[]}'
  exit 0
}

QUALITY_JSON="$("$SCRIPT_DIR/quality-evidence.sh" --base="$BASE_REF" 2>/dev/null || echo '{}')"
if ! echo "$QUALITY_JSON" | jq -e . >/dev/null 2>&1; then
  QUALITY_JSON='{}'
fi

TASK_TXT=""
if [[ -n "$TASK_FILE" && -f "$TASK_FILE" ]]; then
  TASK_TXT="$(head -c 3000 "$TASK_FILE" 2>/dev/null || true)"
fi

DIFF_SUMMARY=""
if [[ -n "$DIFF_FILE" && -f "$DIFF_FILE" ]]; then
  DIFF_SUMMARY="$(grep -E '^(diff --git|\\+\\+\\+|--- |@@)' "$DIFF_FILE" 2>/dev/null | head -n 80 || true)"
fi

CHANGED="$(echo "$QUALITY_JSON" | jq -r '.changed_files[]?')"

RELATED_TESTS='[]'
while IFS= read -r path; do
  [[ -z "$path" ]] && continue
  base="$(basename "$path")"
  stem="${base%.*}"
  [[ -z "$stem" || "$stem" == "$base" ]] && stem="$base"

  # Changed tests are directly relevant. Nearby tests sharing the filename stem
  # are useful hints but bounded so the packet stays cheap.
  matches="$(
    {
      printf '%s\n' "$path" | grep -E '(^|/)(test|tests|spec|__tests__)(/|$)|\.(test|spec)\.(js|jsx|ts|tsx|py)$|_test\.go$' || true
      if command -v rg >/dev/null 2>&1 && [[ ${#stem} -ge 3 ]]; then
        rg --files -g '!node_modules/**' -g '!vendor/**' -g '!.git/**' -g '!.cc-boost/**' 2>/dev/null \
          | grep -E '(^|/)(test|tests|spec|__tests__)(/|$)|\.(test|spec)\.(js|jsx|ts|tsx|py)$|_test\.go$' \
          | grep -F "$stem" || true
      fi
    } | sort -u | head -n 20
  )"
  if [[ -n "$matches" ]]; then
    RELATED_TESTS="$(printf '%s\n' "$matches" | jq -R . | jq -s --argjson old "$RELATED_TESTS" '$old + map(select(.!="")) | unique')"
  fi
done <<< "$CHANGED"

CALLSITE_HINTS='[]'
if command -v rg >/dev/null 2>&1; then
  while IFS= read -r path; do
    [[ -z "$path" || ! -f "$path" ]] && continue
    case "$path" in
      *.md|*.json|*.jsonl|*.lock|*.png|*.jpg|*.jpeg|*.gif) continue ;;
    esac
    stem="$(basename "$path")"
    stem="${stem%.*}"
    [[ ${#stem} -lt 4 ]] && continue
    hits="$(rg -n -F "$stem" -g '!node_modules/**' -g '!vendor/**' -g '!.git/**' -g '!.cc-boost/**' . 2>/dev/null | grep -v -F "$path" | head -n 8 || true)"
    [[ -z "$hits" ]] && continue
    CALLSITE_HINTS="$(jq -n \
      --argjson old "$CALLSITE_HINTS" \
      --arg file "$path" \
      --arg symbol "$stem" \
      --argjson hits "$(printf '%s\n' "$hits" | jq -R . | jq -s 'map(select(.!=""))')" \
      '$old + [{file:$file, symbol:$symbol, hits:$hits}]')"
  done <<< "$CHANGED"
fi

MANIFESTS='[]'
for f in package.json pyproject.toml requirements.txt go.mod Cargo.toml; do
  [[ -f "$f" ]] || continue
  MANIFESTS="$(echo "$MANIFESTS" | jq --arg f "$f" '. + [$f]')"
done

jq -n \
  --argjson quality "$QUALITY_JSON" \
  --arg task "$TASK_TXT" \
  --arg diff_summary "$DIFF_SUMMARY" \
  --argjson related_tests "$RELATED_TESTS" \
  --argjson callsite_hints "$CALLSITE_HINTS" \
  --argjson manifests "$MANIFESTS" \
  '{
    schema_version: 1,
    task: $task,
    quality: $quality,
    diff_summary: $diff_summary,
    related_tests: $related_tests,
    callsite_hints: $callsite_hints,
    project_manifests: $manifests
  }'
