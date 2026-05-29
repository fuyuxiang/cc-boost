#!/usr/bin/env bash
# cc-boost common helpers — sourced by all hook/script wrappers.
# Pure bash + jq. No Node/Python runtime required.

set -uo pipefail

# Resolve the project root (Claude sets CLAUDE_PROJECT_DIR; fall back to cwd).
cc_project_dir() {
  echo "${CLAUDE_PROJECT_DIR:-$PWD}"
}

cc_boost_dir() {
  echo "$(cc_project_dir)/.cc-boost"
}

cc_runtime_dir() {
  local d
  d="$(cc_boost_dir)/runtime"
  mkdir -p "$d" 2>/dev/null || true
  echo "$d"
}

cc_state_dir() {
  local d
  d="$(cc_runtime_dir)/state"
  mkdir -p "$d" 2>/dev/null || true
  echo "$d"
}

cc_failures_path() {
  echo "$(cc_runtime_dir)/failures.jsonl"
}

cc_lessons_path() {
  echo "$(cc_runtime_dir)/lessons.md"
}

cc_baseline_path() {
  echo "$(cc_runtime_dir)/baseline.json"
}

cc_worktrees_dir() {
  local d
  d="$(cc_runtime_dir)/worktrees"
  mkdir -p "$d" 2>/dev/null || true
  echo "$d"
}

cc_bench_dir() {
  local d
  d="$(cc_runtime_dir)/bench"
  mkdir -p "$d" 2>/dev/null || true
  echo "$d"
}

cc_review_packets_dir() {
  local d
  d="$(cc_runtime_dir)/review-packets"
  mkdir -p "$d" 2>/dev/null || true
  echo "$d"
}

cc_config_path() {
  echo "$(cc_boost_dir)/config.json"
}

cc_log() {
  local lvl="$1"; shift
  local logf
  logf="$(cc_state_dir)/cc-boost.log"
  printf '[%s] %s %s\n' "$(date -u +%FT%TZ)" "$lvl" "$*" >> "$logf" 2>/dev/null || true
}

# Read a config key from .cc-boost/config.json with a fallback default.
cc_cfg() {
  local key="$1"; local default="${2:-}"
  local cfg
  cfg="$(cc_config_path)"
  if [[ -f "$cfg" ]] && command -v jq >/dev/null 2>&1; then
    local val
    val="$(jq -r --arg k "$key" 'getpath($k | split("."))' "$cfg" 2>/dev/null)"
    if [[ "$val" != "null" && -n "$val" ]]; then
      echo "$val"; return 0
    fi
  fi
  echo "$default"
}

# Should cc-boost intervene in this turn? Honor an enabled flag and a tripwire
# to disable itself if a previous run produced an internal error.
cc_enabled() {
  [[ "$(cc_cfg enabled true)" == "true" ]]
}

# Emit a JSON object on stdout that injects additionalContext into Claude.
# Used by PostToolUse / UserPromptSubmit / SessionStart hooks.
cc_emit_context() {
  local event="$1"; shift
  local context="$*"
  # Cap at 9000 chars to stay under the 10k hook output cap.
  if [[ ${#context} -gt 9000 ]]; then
    context="${context:0:8990}…[truncated]"
  fi
  jq -n --arg ev "$event" --arg ctx "$context" '{
    hookSpecificOutput: {
      hookEventName: $ev,
      additionalContext: $ctx
    }
  }'
}

# Emit a Stop-decision that asks Claude to keep going (block stop) with a reason.
cc_emit_block_stop() {
  local reason="$1"
  jq -n --arg r "$reason" '{decision:"block", reason:$r}'
}

# Hash a string deterministically (used for task fingerprints).
cc_hash() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print substr($1,1,16)}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print substr($1,1,16)}'
  else
    printf '%s' "$1" | cksum | awk '{print $1}'
  fi
}

# Append a JSON line to a file atomically-ish.
cc_append_jsonl() {
  local file="$1"; shift
  local line="$*"
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$line" >> "$file"
}

# Detect project type. Echoes one of: node, python, go, rust, mixed, unknown.
cc_detect_project() {
  local d; d="$(cc_project_dir)"
  local has_node=0 has_py=0 has_go=0 has_rust=0
  [[ -f "$d/package.json" ]] && has_node=1
  { [[ -f "$d/pyproject.toml" ]] || [[ -f "$d/setup.py" ]] || [[ -f "$d/requirements.txt" ]]; } && has_py=1
  [[ -f "$d/go.mod" ]] && has_go=1
  [[ -f "$d/Cargo.toml" ]] && has_rust=1
  local total=$((has_node + has_py + has_go + has_rust))
  if (( total == 0 )); then echo "unknown"; return; fi
  if (( total > 1 )); then echo "mixed"; return; fi
  (( has_node )) && { echo node; return; }
  (( has_py ))   && { echo python; return; }
  (( has_go ))   && { echo go; return; }
  (( has_rust )) && { echo rust; return; }
}

# Path to the project's agent-check script. We never overwrite the user's
# script — cc-init copies a template if one is missing.
cc_agent_check() {
  echo "$(cc_boost_dir)/agent-check.sh"
}

# Run agent-check and capture stdout+stderr separately.
# Returns the exit code; writes combined output to $2.
cc_run_agent_check() {
  local outfile="$1"
  local script
  script="$(cc_agent_check)"
  if [[ ! -x "$script" ]]; then
    echo "cc-boost: .cc-boost/agent-check.sh missing or not executable" > "$outfile"
    return 127
  fi
  ( cd "$(cc_project_dir)" && bash "$script" ) > "$outfile" 2>&1
}

# Capture a git diff without mutating the index. Untracked files are appended
# as /dev/null diffs and numstat additions so hooks can inspect new files
# without `git add -N`.
cc_git_diff_with_untracked() {
  local base="${1:-HEAD}"
  local diff_file="$2"
  local stat_file="${3:-}"

  : > "$diff_file"
  git diff "$base" >> "$diff_file" 2>/dev/null || true

  if [[ -n "$stat_file" ]]; then
    : > "$stat_file"
    git diff "$base" --numstat >> "$stat_file" 2>/dev/null || true
  fi

  while IFS= read -r path; do
    [[ -z "$path" || ! -f "$path" ]] && continue
    git diff --no-index -- /dev/null "$path" >> "$diff_file" 2>/dev/null || true
    if [[ -n "$stat_file" ]]; then
      local lines
      lines="$(wc -l < "$path" 2>/dev/null | tr -d ' ' || echo 0)"
      printf '%s\t0\t%s\n' "$lines" "$path" >> "$stat_file"
    fi
  done < <(git ls-files --others --exclude-standard 2>/dev/null | grep -vE '^\.cc-boost(/|$)' || true)
}
