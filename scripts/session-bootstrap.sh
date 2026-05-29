#!/usr/bin/env bash
# SessionStart hook. Tells Claude what cc-boost is, what model role assignments
# are in effect, and reminds it about the verifier-gated workflow.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"
# shellcheck source=/dev/null
source "$LIB_DIR/common.sh"

cat >/dev/null

if ! cc_enabled; then exit 0; fi

CFG="$(cc_config_path)"
EXEC_MODEL="$(cc_cfg executor.model unknown)"
EXEC_PROVIDER="$(cc_cfg executor.provider unknown)"
VERIFIER_MODEL="$(cc_cfg verifier.model none)"
VERIFIER_PROVIDER="$(cc_cfg verifier.provider none)"
QUALITY_MODE="$(cc_cfg quality.mode light)"
REGRESSION_ONLY="$(cc_cfg quality.regression_only true)"

# Export executor model into env so other scripts can tag failure ledger entries.
# (Hooks share env via the shell — Claude itself doesn't read this.)
export CC_BOOST_EXECUTOR_MODEL="$EXEC_MODEL"

CONTEXT=$(cat <<EOF
[cc-boost] Active. This session uses a quality-gated coding harness.

Executor : $EXEC_MODEL ($EXEC_PROVIDER)
Verifier : $VERIFIER_MODEL ($VERIFIER_PROVIDER)
Quality  : $QUALITY_MODE (regression_only=$REGRESSION_ONLY)

Working rules in effect (full text in CLAUDE.md):
  1. Inspect relevant files before editing. Plan multi-file changes briefly.
  2. Make small, scoped patches; do not refactor unrelated code or overwrite existing source files with Write.
  3. After every Edit/Write the PostToolUse hook runs .cc-boost/agent-check.sh
     and classifies failures against the captured baseline.
  4. The Stop hook re-runs agent-check. New regressions block finalization;
     known baseline failures are logged but should not expand task scope.
  5. For high-stakes tasks, invoke the \`cc-boost-verifier\` subagent for
     cross-model semantic review with a review packet before declaring success.
  6. Failures are logged to .cc-boost/runtime/failures.jsonl and periodically
     compiled into project lessons that are auto-injected next session.

Use the /cc-task command for hard tasks — it runs Best-of-N across multiple
models and picks the verified candidate with the best quality score, using diff size as a tie-breaker.
EOF
)

cc_emit_context SessionStart "$CONTEXT"
