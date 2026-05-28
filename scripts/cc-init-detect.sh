#!/usr/bin/env bash
# Helper for /cc-init step 1: detect project type. Pure shell.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"
# shellcheck source=/dev/null
source "$LIB_DIR/common.sh"

ptype="$(cc_detect_project)"

# Pick the agent-check template path.
case "$ptype" in
  node)    tmpl="${CLAUDE_PLUGIN_ROOT:-$SCRIPT_DIR/..}/templates/agent-check/node.sh" ;;
  python)  tmpl="${CLAUDE_PLUGIN_ROOT:-$SCRIPT_DIR/..}/templates/agent-check/python.sh" ;;
  go)      tmpl="${CLAUDE_PLUGIN_ROOT:-$SCRIPT_DIR/..}/templates/agent-check/go.sh" ;;
  rust)    tmpl="${CLAUDE_PLUGIN_ROOT:-$SCRIPT_DIR/..}/templates/agent-check/rust.sh" ;;
  *)       tmpl="${CLAUDE_PLUGIN_ROOT:-$SCRIPT_DIR/..}/templates/agent-check/generic.sh" ;;
esac

# Best-effort detection of node package manager.
pm=""
if [[ "$ptype" == "node" ]]; then
  d="$(cc_project_dir)"
  if   [[ -f "$d/pnpm-lock.yaml" ]]; then pm=pnpm
  elif [[ -f "$d/yarn.lock" ]];      then pm=yarn
  elif [[ -f "$d/bun.lockb" ]];      then pm=bun
  else pm=npm; fi
fi

jq -n \
  --arg ptype "$ptype" \
  --arg tmpl "$tmpl" \
  --arg pm "$pm" \
  '{project_type:$ptype, agent_check_template:$tmpl, package_manager:$pm}'
