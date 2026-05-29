#!/usr/bin/env bash
# /cc-task apply — bring the winner's diff back to the user's working tree
# and clean up loser worktrees.
#
# Modes:
#   apply (default): apply the winner's diff onto the user's branch via
#                    git apply -3 (3-way). Leaves the user free to inspect
#                    and commit. Does NOT auto-commit.
#   keep-branch:     keep the winner branch in place; only print its name.
#                    Cleanup of losers still happens.
#
# Cleanup safety:
#   We only ever remove worktrees under .cc-boost/runtime/worktrees/<run-id>/, never
#   anywhere else. Branches removed must match the cc-boost/<run-id>/cand-*
#   pattern. This bounds blast radius if a user manually pokes around inside
#   a cc-boost worktree dir.
#
# Usage:
#   cc-task-apply.sh --run-id=<id> [--mode=apply|keep-branch] [--cleanup-only]
#
# Exit codes:
#   0 = success
#   2 = precondition / apply conflict; user must intervene
#   3 = internal error
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"
# shellcheck source=/dev/null
source "$LIB_DIR/common.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/safety.sh"

die_pre() { echo "cc-task-apply: $*" >&2; exit 2; }
die_int() { echo "cc-task-apply: $*" >&2; exit 3; }

RUN_ID=""; MODE="apply"; CLEANUP_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --run-id=*)     RUN_ID="${arg#--run-id=}" ;;
    --mode=*)       MODE="${arg#--mode=}" ;;
    --cleanup-only) CLEANUP_ONLY=1 ;;
  esac
done

cc_safe_run_id "$RUN_ID" || exit 2
[[ "$MODE" == "apply" || "$MODE" == "keep-branch" ]] || die_pre "mode must be apply|keep-branch"

PROJECT_DIR="$(cc_project_dir)"
RUN_DIR="$(cc_worktrees_dir)/$RUN_ID"
MANIFEST="$RUN_DIR/manifest.json"
EVAL="$RUN_DIR/evaluation.json"

# Defense-in-depth: even with a valid format, confirm the resolved path is
# under the cc-boost worktrees root before doing anything.
WT_ROOT="$(cc_worktrees_dir)"
mkdir -p "$WT_ROOT"
cc_safe_path_under "$RUN_DIR" "$WT_ROOT" || exit 2

[[ -f "$MANIFEST" ]] || die_int "manifest not found: $MANIFEST"

cd "$PROJECT_DIR" || die_int "cannot cd into project dir"
git rev-parse --git-dir >/dev/null 2>&1 || die_int "not a git repo"

# Cleanup-only: remove all worktrees + branches for this run, then exit.
cleanup() {
  local wt branch
  while IFS= read -r wt; do
    [[ -z "$wt" ]] && continue
    # Safety: only remove worktrees whose resolved path is under our
    # run-specific dir.
    if cc_safe_path_under "$wt" "$RUN_DIR" 2>/dev/null; then
      git worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
    else
      echo "cc-task-apply: refusing to remove worktree outside namespace: $wt" >&2
    fi
  done < <(jq -r '.candidates[].worktree' "$MANIFEST")

  while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue
    if cc_safe_branch "$branch" "$RUN_ID" 2>/dev/null; then
      git branch -D "$branch" 2>/dev/null || true
    fi
  done < <(jq -r '.candidates[].branch' "$MANIFEST")

  # Remove the run dir if empty (worktree removal leaves it empty). If audit
  # artifacts (briefs, diff patches, evaluation.json) remain, leave the dir
  # so the user can inspect after-the-fact.
  if rmdir "$RUN_DIR" 2>/dev/null; then
    :
  else
    echo "cc-task-apply: audit artifacts kept at $RUN_DIR (rm -rf to discard)"
  fi
  # Prune any stale worktree refs.
  git worktree prune 2>/dev/null || true
}

if (( CLEANUP_ONLY )); then
  cleanup
  echo "cc-task-apply: cleaned up run $RUN_ID"
  exit 0
fi

[[ -f "$EVAL" ]] || die_pre "no evaluation.json — run cc-task-evaluate first"

WINNER_N="$(jq -r '.winner // empty' "$EVAL")"
if [[ -z "$WINNER_N" || "$WINNER_N" == "null" ]]; then
  die_pre "no acceptable winner — inspect $EVAL and decide manually"
fi

# Resolve winner row.
WINNER_ROW="$(jq --argjson w "$WINNER_N" '.ranking[] | select(.n == $w)' "$EVAL")"
WINNER_BRANCH="$(echo "$WINNER_ROW" | jq -r '.branch')"
WINNER_DIFF="$(echo "$WINNER_ROW" | jq -r '.diff_file')"

# User's working tree must be clean for apply (we don't want to merge into
# unrelated WIP). cc-boost's own dir (.cc-boost/) is excluded — it's our
# private namespace, not user changes. The user is encouraged but not
# required to .gitignore it.
if [[ "$MODE" == "apply" ]] && cc_user_is_dirty; then
  die_pre "working tree must be clean to apply — commit or stash first"
fi

case "$MODE" in
  apply)
    [[ -s "$WINNER_DIFF" ]] || die_pre "winner diff is empty: $WINNER_DIFF"
    if ! git apply --3way --whitespace=nowarn "$WINNER_DIFF"; then
      echo "cc-task-apply: 3-way apply failed; winner branch left at $WINNER_BRANCH" >&2
      echo "cc-task-apply: not running cleanup so you can recover manually." >&2
      exit 2
    fi
    echo "cc-task-apply: applied winner cand-$WINNER_N to working tree (uncommitted)."
    cleanup
    ;;
  keep-branch)
    echo "cc-task-apply: winner branch preserved: $WINNER_BRANCH"
    echo "cc-task-apply: switch to it with: git switch $WINNER_BRANCH"
    # Cleanup losers only.
    while IFS= read -r row; do
      N="$(echo "$row" | jq -r '.n')"
      [[ "$N" == "$WINNER_N" ]] && continue
      WT="$(echo "$row" | jq -r '.worktree')"
      BRANCH="$(echo "$row" | jq -r '.branch')"
      if cc_safe_path_under "$WT" "$RUN_DIR" 2>/dev/null; then
        git worktree remove --force "$WT" 2>/dev/null || rm -rf "$WT"
      fi
      if cc_safe_branch "$BRANCH" "$RUN_ID" 2>/dev/null; then
        git branch -D "$BRANCH" 2>/dev/null || true
      fi
    done < <(jq -c '.ranking[]' "$EVAL")
    git worktree prune 2>/dev/null || true
    ;;
esac

exit 0
