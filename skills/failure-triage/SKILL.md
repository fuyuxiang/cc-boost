---
description: How to read and respond to cc-boost structured failure summaries. Auto-load when a PostToolUse failure summary appears in context.
---

# Reading cc-boost failure summaries

When agent-check fails, cc-boost's PostToolUse hook first compares the
failure to the captured baseline. Treat only **new regression** summaries as
authoritative repair briefs. Known baseline failures are context, not a
request to clean up unrelated code.

## Failure schema

```json
{
  "type":    "ts_error|lint_error|test_failure|build_error|generic",
  "tool":    "tsc|eslint|pytest|cargo|...",
  "files":   ["src/x.ts:42", "src/y.ts:17"],
  "summary": "<one-line>",
  "evidence":"<trimmed log>",
  "suggested_focus": "<actionable hint>"
}
```

## How to use each field

- **type** decides your strategy:
  - `ts_error` / `build_error`: a compile-time problem. Fix it before
    re-running anything else. Don't add tests yet.
  - `lint_error`: a style/correctness rule. Fix the cited rule, do not
    disable it.
  - `test_failure`: behavior is wrong. The test is your spec — change the
    code to satisfy it (unless the test itself is wrong, in which case
    say so to the user before changing the test).
  - `generic`: read the evidence carefully — the classifier didn't match.

- **files**: read ONLY these. Do not open unrelated files. If the failure
  references no files (e.g. broken config), use `grep` to find the
  responsible file.

- **summary**: the one-line headline. Use it to decide if your previous
  diff caused this, or if it's a pre-existing issue.

- **evidence**: the actual log fragment. When the schema is ambiguous,
  read this — it has the ground truth.

- **suggested_focus**: a hint, not a command. Treat it as a starting
  direction, not a complete plan.

## Rules of repair

1. **Smallest patch wins.** A 2-line fix that solves the cited issue is
   strictly better than a 20-line "comprehensive" fix.

2. **Never disable the check.** Don't comment out tests, don't add
   `// eslint-disable`, don't `pytest.skip`, don't `#[allow(...)]`.

3. **Trust the compiler/linter.** If `tsc` says "Property 'x' does not
   exist on type Y," the answer is to fix the type or the access — not
   to cast to `any`.

4. **If the same failure recurs after one repair attempt:** stop
   patching. The repair is wrong. Step back, re-read the original task,
   and consider a different approach. Tell the user.

5. **Never silently expand scope.** If fixing the failure would require
   changing files outside the original task scope, surface that to the
   user before doing it.

## What gets logged

Every failure (whether you fix it or not) is appended to
`.cc-boost/runtime/failures.jsonl` and eventually compiled into project lessons.
This means: if you make the same kind of mistake repeatedly across
sessions, future-you will see a lesson about it injected next time. So
the cost of writing bad code now is paid by future-you. Write good code now.
