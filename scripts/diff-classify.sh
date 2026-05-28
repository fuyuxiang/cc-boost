#!/usr/bin/env bash
# Classify the current working-tree diff so the final gate can decide whether
# to invoke the cross-model verifier. Output: a single-line JSON object with
# fields {files,lines,trivial,hash}. Always exits 0 — callers branch on JSON.
#
# Strategy:
#   - "diff" = `git diff HEAD` (staged + unstaged), so a turn that committed
#     mid-flight still gets reviewed against HEAD-before-the-turn? Actually,
#     final-gate runs at Stop, by which point the model may or may not have
#     committed. We capture both staged and unstaged via `git diff HEAD`,
#     which covers everything that differs from HEAD.
#   - Outside a git repo OR no diff: emit trivial:true with empty hash so the
#     caller short-circuits.
#   - Hash uses sha256 over the diff body so the verifier-cache key is stable
#     across hook invocations within the same logical change.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"
# shellcheck source=/dev/null
source "$LIB_DIR/common.sh"

PROJECT_DIR="$(cc_project_dir)"
cd "$PROJECT_DIR" 2>/dev/null || {
  jq -n '{files:0, lines:0, trivial:true, hash:"", reason:"no project dir"}'
  exit 0
}

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  jq -n '{files:0, lines:0, trivial:true, hash:"", reason:"not a git repo"}'
  exit 0
fi

# Capture diff vs HEAD covering staged + unstaged. Use `git add -N` to
# include untracked files (intent-to-add) so newly created files show up in
# `git diff HEAD` as additions of every line. Restore the index afterwards
# so we don't pollute the working tree's staging state.
UNTRACKED="$(git ls-files --others --exclude-standard 2>/dev/null || true)"
if [[ -n "$UNTRACKED" ]]; then
  # shellcheck disable=SC2086
  git add -N -- $UNTRACKED 2>/dev/null || true
fi

DIFF="$(git diff HEAD 2>/dev/null || true)"
STAT="$(git diff HEAD --numstat 2>/dev/null || true)"

# Restore index — drop the intent-to-add entries we just created.
if [[ -n "$UNTRACKED" ]]; then
  # shellcheck disable=SC2086
  git reset -q -- $UNTRACKED 2>/dev/null || true
fi

if [[ -z "$DIFF" ]]; then
  jq -n '{files:0, lines:0, trivial:true, hash:"", reason:"no changes"}'
  exit 0
fi

FILES=0; LINES=0
while IFS=$'\t' read -r added removed _; do
  [[ -z "$added" ]] && continue
  FILES=$((FILES + 1))
  # binary diffs show "-" for counts; treat as 0.
  [[ "$added"   == "-" ]] && added=0
  [[ "$removed" == "-" ]] && removed=0
  LINES=$((LINES + added + removed))
done <<< "$STAT"

MIN_FILES="$(cc_cfg verifier.min_files 1)"
MIN_LINES="$(cc_cfg verifier.min_lines 20)"

# Non-trivial requires BOTH thresholds met. Falling short of either keeps the
# diff trivial (verifier not invoked).
TRIVIAL="false"
if (( FILES < MIN_FILES )) || (( LINES < MIN_LINES )); then
  TRIVIAL="true"
fi

HASH="$(printf '%s' "$DIFF" | { command -v shasum >/dev/null 2>&1 && shasum -a 256 || sha256sum; } | awk '{print $1}')"

jq -n \
  --argjson files "$FILES" \
  --argjson lines "$LINES" \
  --arg trivial "$TRIVIAL" \
  --arg hash "$HASH" \
  '{files:$files, lines:$lines, trivial:($trivial=="true"), hash:$hash}'
