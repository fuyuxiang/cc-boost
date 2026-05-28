---
description: Compile .cc-boost/failures.jsonl into a fresh .cc-boost/lessons.md. Run periodically (every 50 failures or weekly). Lessons are auto-injected into every UserPromptSubmit by the inject-lessons hook.
allowed-tools: Bash, Read, Write, Agent
argument-hint: "[--min-cluster=2] [--max-per-section=8]"
---

You are running `/cc-compile-lessons`. Convert failures into a short, useful
rules file. The output is auto-injected next session.

## Steps

1. Read `.cc-boost/failures.jsonl`. If absent or empty, write a stub
   `lessons.md` with just the header and exit. Tell the user "no failures to
   learn from yet."

2. Pre-filter: drop entries older than 60 days. Keep at most the most-recent
   500 entries (older patterns are likely already obsolete).

3. Invoke the `cc-boost-lesson-compiler` subagent with the filtered ledger
   content as input. The subagent will produce a complete lessons.md body.

4. Write the result to `.cc-boost/lessons.md`. Update the "Last compiled"
   timestamp to the current ISO time.

5. Print a one-line summary: `Compiled N lessons from M failure entries.`

## Hard rules

- Never edit `.cc-boost/failures.jsonl` — it's append-only.
- Never write any file other than `.cc-boost/lessons.md`.
- If the compiler subagent returns malformed markdown, do NOT write it —
  preserve the existing lessons.md and tell the user.
