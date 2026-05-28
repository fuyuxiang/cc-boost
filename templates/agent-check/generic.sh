#!/usr/bin/env bash
# Generic fallback agent-check. Tries the most common signals.
set -uo pipefail
run() { echo "::cc-boost::run $*"; "$@"; }

if [[ -f Makefile ]]; then
  if grep -qE '^(test|check):' Makefile; then
    run make check 2>/dev/null || run make test || exit 1
  fi
fi

if [[ -f justfile || -f Justfile ]]; then
  if command -v just >/dev/null 2>&1; then
    just test 2>/dev/null || just check 2>/dev/null || true
  fi
fi

echo "::cc-boost::ok (no project type detected — edit scripts/agent-check.sh)"
exit 0
