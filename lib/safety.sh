#!/usr/bin/env bash
# cc-boost safety helpers. Sourced by scripts that take run-ids, build paths
# from user/Claude-supplied tokens, or remove worktrees/branches. The point
# is to keep the validation rules in one place — drift between scripts is
# how blast-radius bugs sneak in.
#
# All helpers return 0 on success, non-zero on failure, and print a single
# diagnostic line to stderr on failure. They never delete or mutate.

# Validate a /cc-task run-id. Format: <UTC-compact>-<16 hex>.
# Examples:
#   20260528T103359Z-ecf2ea9b6aed3210  -> ok
#   ../etc/passwd                       -> reject
cc_safe_run_id() {
  local id="$1"
  if [[ -z "$id" ]]; then
    echo "cc-safety: empty run-id" >&2; return 1
  fi
  if [[ ! "$id" =~ ^[0-9TZ]+-[0-9a-f]+$ ]]; then
    echo "cc-safety: invalid run-id format: $id" >&2; return 1
  fi
  # Length sanity: prevent absurdly long inputs.
  if (( ${#id} > 128 )); then
    echo "cc-safety: run-id too long" >&2; return 1
  fi
  return 0
}

# Validate that $candidate path resolves to something *inside* $root after
# both are realpath'd. Catches symlink/.. escapes regardless of OS.
# Usage: cc_safe_path_under "$candidate" "$root"
cc_safe_path_under() {
  local candidate="$1"; local root="$2"
  [[ -n "$candidate" && -n "$root" ]] || { echo "cc-safety: path or root missing" >&2; return 1; }

  # Resolve root strictly — must already exist.
  local rroot
  if command -v realpath >/dev/null 2>&1; then
    rroot="$(realpath "$root" 2>/dev/null || true)"
  else
    rroot="$(cd "$root" 2>/dev/null && pwd)"
  fi
  [[ -n "$rroot" ]] || { echo "cc-safety: cannot resolve root: $root" >&2; return 1; }

  # Resolve candidate leniently — it may not exist yet (we're about to create).
  # Use the parent dir + basename trick.
  local rcand parent base
  if [[ -e "$candidate" ]]; then
    if command -v realpath >/dev/null 2>&1; then
      rcand="$(realpath "$candidate" 2>/dev/null || true)"
    else
      rcand="$(cd "$candidate" 2>/dev/null && pwd || true)"
    fi
  else
    parent="$(dirname "$candidate")"
    base="$(basename "$candidate")"
    if [[ -d "$parent" ]]; then
      if command -v realpath >/dev/null 2>&1; then
        rcand="$(realpath "$parent" 2>/dev/null)/$base"
      else
        rcand="$(cd "$parent" 2>/dev/null && pwd)/$base"
      fi
    else
      echo "cc-safety: parent missing: $parent" >&2; return 1
    fi
  fi
  [[ -n "$rcand" ]] || { echo "cc-safety: cannot resolve candidate: $candidate" >&2; return 1; }

  case "$rcand" in
    "$rroot"|"$rroot"/*) return 0 ;;
    *) echo "cc-safety: path escapes root ($rcand not under $rroot)" >&2; return 1 ;;
  esac
}

# Validate that $branch matches the cc-boost candidate naming pattern.
# Usage: cc_safe_branch "$branch" "$run_id"
cc_safe_branch() {
  local branch="$1"; local run_id="$2"
  cc_safe_run_id "$run_id" || return 1
  if [[ ! "$branch" =~ ^cc-boost/${run_id}/cand-[0-9]+$ ]]; then
    echo "cc-safety: branch outside cc-boost namespace: $branch" >&2; return 1
  fi
  return 0
}

# Stdin filter: emit only files in `git status --porcelain` output that are
# NOT under .cc-boost/ — i.e. real user changes. Used to gate "clean working
# tree" checks across cc-task scripts.
cc_user_dirty_paths() {
  awk '{path=$0; sub(/^...?/, "", path); print path}' \
    | grep -vE '^\.cc-boost(/|$)' || true
}

# Convenience: returns 0 if the user has uncommitted changes outside .cc-boost/.
cc_user_is_dirty() {
  git status --porcelain 2>/dev/null | cc_user_dirty_paths | grep -q .
}
