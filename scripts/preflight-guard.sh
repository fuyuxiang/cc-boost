#!/usr/bin/env bash
# PreToolUse guard for high-risk write patterns. It blocks only deterministic
# cases that commonly inflate diffs or hide regressions.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"
# shellcheck source=/dev/null
source "$LIB_DIR/common.sh"

HOOK_INPUT="$(cat || true)"
if ! cc_enabled; then exit 0; fi
if [[ "$(cc_cfg quality.preflight true)" != "true" ]]; then exit 0; fi
if [[ -z "$HOOK_INPUT" ]] || ! command -v jq >/dev/null 2>&1; then exit 0; fi

TOOL="$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_name // .tool // empty' 2>/dev/null || true)"
FILE_PATH="$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null || true)"

[[ -n "$FILE_PATH" ]] || exit 0

PROJECT_DIR="$(cc_project_dir)"
case "$FILE_PATH" in
  /*) ABS_PATH="$FILE_PATH" ;;
  *) ABS_PATH="$PROJECT_DIR/$FILE_PATH" ;;
esac

REL_PATH="$FILE_PATH"
case "$ABS_PATH" in
  "$PROJECT_DIR"/*) REL_PATH="${ABS_PATH#"$PROJECT_DIR"/}" ;;
esac

# Avoid blocking cc-boost runtime state writes.
case "$REL_PATH" in
  .cc-boost/*) exit 0 ;;
esac

block() {
  local reason="$1"
  jq -n --arg r "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

if [[ "$TOOL" == "Write" && -f "$ABS_PATH" ]]; then
  case "$REL_PATH" in
    *.md|*.txt|*.jsonl) ;;
    *)
      block "[cc-boost] Preflight guard: Write would replace existing file '$REL_PATH'. Use Edit/MultiEdit for scoped patches, or set quality.preflight=false for this project."
      ;;
  esac
fi

case "$REL_PATH" in
  package-lock.json|pnpm-lock.yaml|yarn.lock|bun.lockb|Cargo.lock|go.sum)
    block "[cc-boost] Preflight guard: lockfile changes require an explicit dependency task. Ask the user or disable quality.preflight before editing '$REL_PATH'."
    ;;
esac

exit 0
