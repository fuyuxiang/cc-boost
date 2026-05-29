#!/usr/bin/env bash
# Build a stable-ish fingerprint for a summarized deterministic-check failure.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"
# shellcheck source=/dev/null
source "$LIB_DIR/common.sh"

INPUT="${1:-}"
if [[ -z "$INPUT" ]]; then
  INPUT="$(cat || true)"
fi

if ! echo "$INPUT" | jq -e . >/dev/null 2>&1; then
  cc_hash "$INPUT"
  exit 0
fi

KEY="$(echo "$INPUT" | jq -r '
  [
    (.type // "generic"),
    (.tool // "unknown"),
    (.summary // ""),
    ((.files // []) | map(tostring | sub(":[0-9]+$"; "")) | sort | join(","))
  ] | @tsv
' 2>/dev/null || true)"

cc_hash "$KEY"
exit 0
