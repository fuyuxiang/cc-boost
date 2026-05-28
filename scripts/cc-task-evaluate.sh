#!/usr/bin/env bash
# /cc-task evaluate — for each candidate worktree: run Layer A, capture diff,
# run cross-family verifier (if enabled), then apply the selection rule.
# Outputs a ranking JSON on stdout including the chosen winner. Does not
# apply or clean — that's cc-task-apply.sh's job (separated for safety).
#
# Selection rule (in order):
#   1. Exclude candidates that failed Layer A or verifier.
#   2. Prefer verdict==pass over uncertain over skipped.
#   3. Smallest diff_lines.
#   4. Tie-break on verifier_score (highest).
#
# Usage:
#   cc-task-evaluate.sh --run-id=<id> [--no-verifier]
#
# Exit codes:
#   0 = success, ranking JSON on stdout, winner field set if any
#   2 = no acceptable winner (all failed Layer A, verifier, or both); ranking
#       still printed so the user can inspect
#   3 = internal error
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"
# shellcheck source=/dev/null
source "$LIB_DIR/common.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/safety.sh"

die_int() { echo "cc-task-evaluate: $*" >&2; exit 3; }

RUN_ID=""
NO_VERIFIER=0
for arg in "$@"; do
  case "$arg" in
    --run-id=*)     RUN_ID="${arg#--run-id=}" ;;
    --no-verifier)  NO_VERIFIER=1 ;;
  esac
done

cc_safe_run_id "$RUN_ID" || exit 2

PROJECT_DIR="$(cc_project_dir)"
RUN_DIR="$(cc_boost_dir)/worktrees/$RUN_ID"
MANIFEST="$RUN_DIR/manifest.json"
[[ -f "$MANIFEST" ]] || die_int "manifest not found: $MANIFEST (did setup run?)"

BASE_SHA="$(jq -r '.base_sha' "$MANIFEST")"
TASK="$(jq -r '.task' "$MANIFEST")"

# Materialize the task description as a file once — verifier will read it.
TASK_FILE="$RUN_DIR/task.txt"
printf '%s\n' "$TASK" > "$TASK_FILE"

# Iterate candidates from manifest.
CAND_COUNT="$(jq '.candidates | length' "$MANIFEST")"
RANKING='[]'

for i in $(seq 0 $((CAND_COUNT - 1))); do
  N="$(jq -r ".candidates[$i].n" "$MANIFEST")"
  WT="$(jq -r ".candidates[$i].worktree" "$MANIFEST")"
  BRANCH="$(jq -r ".candidates[$i].branch" "$MANIFEST")"

  # Layer A — run agent-check.sh inside the candidate worktree.
  LOG_FILE="$RUN_DIR/cand-$N.layer-a.log"
  AC="$WT/scripts/agent-check.sh"
  if [[ -x "$AC" ]]; then
    ( cd "$WT" && bash "$AC" ) > "$LOG_FILE" 2>&1
    LAYER_A_RC=$?
  else
    echo "scripts/agent-check.sh missing in worktree" > "$LOG_FILE"
    LAYER_A_RC=127
  fi
  LAYER_A_PASS="false"; (( LAYER_A_RC == 0 )) && LAYER_A_PASS="true"

  # Diff vs base — include untracked the candidate may have created.
  DIFF_FILE="$RUN_DIR/cand-$N.diff.patch"
  STAT_FILE="$RUN_DIR/cand-$N.numstat"
  (
    cd "$WT" || exit 0
    UNTRACKED=()
    while IFS= read -r -d '' path; do
      UNTRACKED+=("$path")
    done < <(git ls-files --others --exclude-standard -z 2>/dev/null || true)
    if (( ${#UNTRACKED[@]} > 0 )); then
      git add -N -- "${UNTRACKED[@]}" 2>/dev/null || true
    fi
    git diff "$BASE_SHA" > "$DIFF_FILE" 2>/dev/null || true
    git diff "$BASE_SHA" --numstat > "$STAT_FILE" 2>/dev/null || true
    if (( ${#UNTRACKED[@]} > 0 )); then
      git reset -q -- "${UNTRACKED[@]}" 2>/dev/null || true
    fi
  )

  # Diff stats.
  DIFF_FILES=0; DIFF_LINES=0
  if [[ -s "$STAT_FILE" ]]; then
    while IFS=$'\t' read -r added removed _; do
      [[ -z "$added" ]] && continue
      DIFF_FILES=$((DIFF_FILES + 1))
      [[ "$added"   == "-" ]] && added=0
      [[ "$removed" == "-" ]] && removed=0
      DIFF_LINES=$((DIFF_LINES + added + removed))
    done < "$STAT_FILE"
  fi

  # Layer B — cross-family verifier.
  VERDICT="skipped"; SCORE="null"; VERDICT_JSON='{}'
  if (( NO_VERIFIER == 0 )) && [[ -s "$DIFF_FILE" ]]; then
    VERDICT_JSON="$("$SCRIPT_DIR/run-verifier.sh" \
      --task-file="$TASK_FILE" \
      --diff-file="$DIFF_FILE" \
      --layer-a-log="$LOG_FILE" 2>/dev/null || true)"
    if [[ -n "$VERDICT_JSON" ]]; then
      VERDICT="$(echo "$VERDICT_JSON" | jq -r '.verdict // "skipped"')"
      SCORE_RAW="$(echo "$VERDICT_JSON" | jq -r '.score // "null"')"
      SCORE="$SCORE_RAW"
    fi
  fi

  # Append to ranking.
  RANKING="$(echo "$RANKING" | jq \
    --argjson n "$N" \
    --arg wt "$WT" \
    --arg branch "$BRANCH" \
    --arg layer_a "$LAYER_A_PASS" \
    --arg verdict "$VERDICT" \
    --argjson files "$DIFF_FILES" \
    --argjson lines "$DIFF_LINES" \
    --arg score "$SCORE" \
    --argjson vobj "${VERDICT_JSON:-{\}}" \
    --arg diff "$DIFF_FILE" \
    --arg log "$LOG_FILE" \
    '. + [{
      n:$n, worktree:$wt, branch:$branch,
      layer_a_pass:($layer_a=="true"),
      verdict:$verdict,
      diff_files:$files,
      diff_lines:$lines,
      verifier_score:(if $score=="null" or $score=="" then null else ($score|tonumber? // null) end),
      verifier_full:$vobj,
      diff_file:$diff,
      layer_a_log:$log
    }]')"
done

# Selection: deterministic, no model in the loop.
WINNER_N="$(echo "$RANKING" | jq '
  map(select(.layer_a_pass == true and .verdict != "fail"))    # rule 1
  | sort_by(
      (if .verdict == "pass" then 0
       elif .verdict == "uncertain" then 1
       else 2 end),                                            # rule 2
      .diff_lines,                                             # rule 3
      (- (.verifier_score // 0))                               # rule 4
    )
  | .[0].n // null
')"

# Persist evaluation summary into the run dir for /cc-ledger and apply step.
EVAL_FILE="$RUN_DIR/evaluation.json"
jq -n \
  --arg run_id "$RUN_ID" \
  --argjson ranking "$RANKING" \
  --argjson winner "${WINNER_N:-null}" \
  '{run_id:$run_id, ranking:$ranking, winner:$winner}' \
  > "$EVAL_FILE"

# Append per-candidate ledger entries.
TS="$(date -u +%FT%TZ)"
EXEC_MODEL="${CC_BOOST_EXECUTOR_MODEL:-unknown}"
echo "$RANKING" | jq -c '.[]' | while read -r row; do
  N="$(echo "$row" | jq -r '.n')"
  PHASE="bon-loser"
  if [[ "$N" == "$WINNER_N" ]]; then PHASE="bon-winner"; fi
  jq -n \
    --arg ts "$TS" \
    --arg phase "$PHASE" \
    --arg model "$EXEC_MODEL" \
    --arg run_id "$RUN_ID" \
    --argjson row "$row" \
    '{ts:$ts, phase:$phase, executor_model:$model, run_id:$run_id, candidate:$row}' \
    >> "$(cc_failures_path)"
done

cat "$EVAL_FILE"

if [[ "$WINNER_N" == "null" || -z "$WINNER_N" ]]; then
  exit 2
fi
exit 0
