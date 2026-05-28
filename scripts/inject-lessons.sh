#!/usr/bin/env bash
# UserPromptSubmit hook. Inject just-in-time context:
#   1. The project's currently-relevant lessons (filtered by current executor model).
#   2. A reminder of the harness workflow (compact form).
# Cap injection to ~2000 chars total — we never want to bloat the prompt.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"
# shellcheck source=/dev/null
source "$LIB_DIR/common.sh"

# Capture the user's prompt for later reuse by the verifier (Layer B needs the
# task description). The hook stdin is JSON; pull .prompt and stash it.
HOOK_INPUT="$(cat || true)"
if [[ -n "$HOOK_INPUT" ]] && command -v jq >/dev/null 2>&1; then
  PROMPT="$(printf '%s' "$HOOK_INPUT" | jq -r '.prompt // empty' 2>/dev/null || true)"
  if [[ -n "$PROMPT" ]]; then
    STATE_DIR="$(cc_state_dir)"
    printf '%s' "$PROMPT" > "$STATE_DIR/last-prompt.txt" 2>/dev/null || true
  fi
fi

if ! cc_enabled; then exit 0; fi

PROJECT_DIR="$(cc_project_dir)"
LESSONS_FILE="$(cc_boost_dir)/lessons.md"
EXEC_MODEL="${CC_BOOST_EXECUTOR_MODEL:-unknown}"

CONTEXT=""
if [[ -f "$LESSONS_FILE" ]]; then
  # Extract only the section for the current executor model, plus the
  # provider-agnostic "all" section if present.
  GLOBAL_SECTION=$(awk '/^## all$/{p=1;next}/^## /{p=0}p' "$LESSONS_FILE" | head -c 1500)
  MODEL_SECTION=""
  if [[ -n "$EXEC_MODEL" ]]; then
    MODEL_SECTION=$(awk -v tag="## $EXEC_MODEL" '$0==tag{p=1;next}/^## /{p=0}p' "$LESSONS_FILE" | head -c 1500)
  fi
  if [[ -n "$GLOBAL_SECTION" || -n "$MODEL_SECTION" ]]; then
    CONTEXT="[cc-boost] Project lessons (compiled from past failures):

$GLOBAL_SECTION

$MODEL_SECTION

Apply these before writing code. They reflect mistakes already seen in this repo."
  fi
fi

if [[ -z "$CONTEXT" ]]; then exit 0; fi

cc_emit_context UserPromptSubmit "$CONTEXT"
