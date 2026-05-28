#!/usr/bin/env bash
# /cc-task setup — prepare N candidate worktrees and a brief per candidate.
#
# Output: a single JSON object on stdout with the run id, base branch, and
# per-candidate metadata (worktree path, branch, brief file). The Claude-side
# command reads this and spawns one cc-boost-candidate Agent per candidate
# slot in parallel, passing the brief.
#
# This script never spawns subagents itself — it can't (no Agent tool from
# bash). Its job is the deterministic, machine-side scaffolding that we
# don't want a weak model to hand-roll.
#
# Usage:
#   cc-task-setup.sh --task=<text> [--n=2] [--budget=medium]
#
# Exit codes:
#   0 = success, JSON on stdout
#   2 = precondition failed (dirty tree, not a git repo, etc.) — message on stderr
#   3 = internal error
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"
# shellcheck source=/dev/null
source "$LIB_DIR/common.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/safety.sh"

die_pre() { echo "cc-task-setup: $*" >&2; exit 2; }
die_int() { echo "cc-task-setup: $*" >&2; exit 3; }

TASK=""; N=2; BUDGET="medium"
for arg in "$@"; do
  case "$arg" in
    --task=*)   TASK="${arg#--task=}" ;;
    --n=*)      N="${arg#--n=}" ;;
    --budget=*) BUDGET="${arg#--budget=}" ;;
  esac
done

[[ -n "$TASK" ]] || die_pre "missing --task=<description>"
[[ "$N" =~ ^[1-3]$ ]] || die_pre "N must be 1, 2, or 3 (got: $N)"
[[ "$BUDGET" == "low" || "$BUDGET" == "medium" || "$BUDGET" == "high" ]] \
  || die_pre "budget must be low|medium|high"

# Budget=low pins N=1 (degenerates to plain harness).
[[ "$BUDGET" == "low" ]] && N=1
# Budget != high caps N at 2.
[[ "$BUDGET" != "high" && "$N" -gt 2 ]] && N=2

PROJECT_DIR="$(cc_project_dir)"
cd "$PROJECT_DIR" || die_int "cannot cd into project dir"

git rev-parse --git-dir >/dev/null 2>&1 || die_pre "not a git repo"

# Working tree must be clean — we don't want to stash or carry uncommitted
# state into worktrees. cc-boost's own dir (.cc-boost/) is excluded — it's
# our private namespace, not user changes.
if cc_user_is_dirty; then
  die_pre "working tree must be clean (uncommitted changes detected)"
fi

# Base branch — the branch the user is currently on; that's what each
# candidate worktree branches from and what we diff against later.
BASE_BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
[[ -n "$BASE_BRANCH" ]] || die_pre "detached HEAD — please checkout a branch before /cc-task"

BASE_SHA="$(git rev-parse HEAD)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$(cc_hash "$TASK")"
RUN_DIR="$(cc_boost_dir)/worktrees/$RUN_ID"
mkdir -p "$RUN_DIR" || die_int "cannot create $RUN_DIR"

# Per-candidate strategy hints. Diversity matters — see arXiv 2605.14163.
strategy_for() {
  case "$1" in
    1) echo "Pick the most direct / obvious approach." ;;
    2) echo "Pick the SECOND-most-likely approach — explicitly different from the obvious one. Different decomposition, different file structure, or different algorithm." ;;
    3) echo "Pick the MOST CONSERVATIVE possible change. Smallest plausible diff, even if it means a less elegant solution." ;;
    *) echo "Pick whatever approach you think is best." ;;
  esac
}

# Build candidates array.
CANDS_JSON='[]'
for i in $(seq 1 "$N"); do
  WT_PATH="$RUN_DIR/cand-$i"
  BRANCH="cc-boost/$RUN_ID/cand-$i"
  BRIEF="$RUN_DIR/cand-$i.brief.md"

  # Create worktree. `git worktree add -b` creates the branch and checks it out.
  if ! git worktree add -b "$BRANCH" "$WT_PATH" "$BASE_SHA" >/dev/null 2>&1; then
    die_int "git worktree add failed for cand-$i"
  fi

  STRATEGY="$(strategy_for "$i")"

  # Brief: what the candidate agent will read.
  cat > "$BRIEF" <<EOF
# cc-boost candidate brief — cand-$i (run $RUN_ID)

## Task

$TASK

## Strategy hint

$STRATEGY

## Working directory

$WT_PATH (already checked out on branch $BRANCH from base $BASE_BRANCH @ ${BASE_SHA:0:12})

## Hard rules

- Do NOT push, commit-amend, or modify any branch other than $BRANCH.
- Do NOT modify files outside the task's stated scope.
- Run \`scripts/agent-check.sh\` before yielding. If it fails, document the
  remaining failure in your final JSON instead of declaring success.
- Final message: emit ONLY the JSON object specified in the candidate
  agent's system prompt — no prose around it.
EOF

  CANDS_JSON="$(echo "$CANDS_JSON" | jq \
    --argjson n "$i" \
    --arg wt "$WT_PATH" \
    --arg branch "$BRANCH" \
    --arg brief "$BRIEF" \
    --arg strategy "$STRATEGY" \
    '. + [{n:$n, worktree:$wt, branch:$branch, brief:$brief, strategy:$strategy}]')"
done

# Persist run manifest so evaluate / apply can find this run by id.
MANIFEST="$RUN_DIR/manifest.json"
jq -n \
  --arg run_id "$RUN_ID" \
  --arg task "$TASK" \
  --arg base_branch "$BASE_BRANCH" \
  --arg base_sha "$BASE_SHA" \
  --argjson n "$N" \
  --arg budget "$BUDGET" \
  --argjson candidates "$CANDS_JSON" \
  '{run_id:$run_id, task:$task, base_branch:$base_branch, base_sha:$base_sha, n:$n, budget:$budget, candidates:$candidates}' \
  > "$MANIFEST"

cat "$MANIFEST"
