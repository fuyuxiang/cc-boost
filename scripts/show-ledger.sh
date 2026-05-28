#!/usr/bin/env bash
# Pretty-print .cc-boost/failures.jsonl.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"
# shellcheck source=/dev/null
source "$LIB_DIR/common.sh"

LIMIT=20
TYPE_FILTER=""
for arg in "$@"; do
  case "$arg" in
    --limit=*) LIMIT="${arg#--limit=}" ;;
    --type=*)  TYPE_FILTER="${arg#--type=}" ;;
  esac
done

LEDGER="$(cc_failures_path)"
if [[ ! -f "$LEDGER" || ! -s "$LEDGER" ]]; then
  echo "cc-boost：账本为空，尚无失败记录。"
  exit 0
fi

TOTAL=$(wc -l < "$LEDGER" | tr -d ' ')
echo "cc-boost 失败账本：$LEDGER"
echo "条目总数：$TOTAL"
echo ""

echo "按失败类型分组（failure.type）："
jq -r '.failure.type' "$LEDGER" 2>/dev/null | sort | uniq -c | sort -rn | head -n 10
echo ""

echo "按 executor 模型分组："
jq -r '.executor_model // "unknown"' "$LEDGER" 2>/dev/null | sort | uniq -c | sort -rn | head -n 10
echo ""

echo "最近条目（latest $LIMIT）："
if [[ -n "$TYPE_FILTER" ]]; then
  jq -c --arg t "$TYPE_FILTER" 'select(.failure.type==$t)' "$LEDGER" 2>/dev/null \
    | tail -n "$LIMIT"
else
  tail -n "$LIMIT" "$LEDGER"
fi | jq -r '
  "\(.ts)  [\(.executor_model // "?")]  \(.failure.type)  — \(.failure.summary // "")"
' 2>/dev/null
