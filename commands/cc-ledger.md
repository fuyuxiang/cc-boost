---
description: Show the cc-boost failure ledger. Pretty-prints recent entries from .cc-boost/failures.jsonl grouped by error type, with frequency counts.
allowed-tools: Bash, Read
argument-hint: "[--limit=20] [--type=ts_error|test_failure|...]"
---

Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/show-ledger.sh" $ARGUMENTS` and
print the result verbatim.

The script:
- Reads `.cc-boost/failures.jsonl`.
- Groups by `failure.type`.
- Shows count per type and the N most recent entries with summary lines.
- If `--type=` is passed, filters to that type.
- If `--limit=N` is passed, caps total rows at N.

If the ledger is empty, say so and suggest the user trigger some failures
naturally before running again.
