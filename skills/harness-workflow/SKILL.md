---
description: The 7-step cc-boost coding workflow. Auto-load this skill whenever the user asks for a code change, bugfix, refactor, or feature. It encodes the verifier-gated harness rules so weak models stay scoped, small, and verified.
---

# cc-boost coding workflow

When the user asks for a code change in a project where cc-boost is active,
follow this strict 7-step procedure. The hooks will enforce parts of it
automatically; this skill keeps you aligned with the harness so you do not
fight it.

## Step 1 — Inspect

Before editing anything:
- Use `Read` on the files most likely involved.
- Use `Grep` to find call sites of any function you are about to modify.
- Use `Glob` to map the relevant directory structure.

Do NOT skip this even for small tasks. Reading 3 files takes 5 seconds and
saves a 30-second wrong-direction diff.

## Step 2 — Plan (only when ≥2 files affected)

State, in 5 lines or fewer:
- Which files you will modify.
- Which functions / sections within them.
- The smallest behavior change that satisfies the task.

If only 1 file is involved, skip the plan and go straight to step 3.

## Step 3 — Patch

Make the smallest scoped edit. Hard rules:
- One logical change per Edit call.
- Do NOT refactor unrelated code "while you're there."
- Do NOT introduce new dependencies.
- Do NOT change public API shapes unless that IS the task.
- Do NOT add try/except just to hide errors.

## Step 4 — Verify (automatic)

After every Edit/Write, the cc-boost PostToolUse hook runs
`scripts/agent-check.sh`. If it fails, you will receive a structured
failure summary as injected context. Your next action MUST be:
- Read only the files cited in `failure.files`.
- Apply the smallest fix that addresses `failure.suggested_focus`.
- Do not expand scope to "fix related issues."

If the same failure recurs **twice in a row**, STOP patching. Step back
and reconsider the approach. Tell the user what you are stuck on.

## Step 5 — Stop-gate (automatic)

When you try to finalize, the Stop hook re-runs agent-check. If it fails,
you cannot exit. Repair, then try to finalize again.

## Step 6 — Cross-model verify (manual; for non-trivial diffs)

If the diff touches ≥3 files OR ≥80 lines, invoke the `cc-boost-verifier`
subagent before declaring the task done. The verifier runs on a model from
a different family than the executor (this is the de-correlated error
detection that lifts weak-model accuracy).

Pass the verifier:
- The original task description (verbatim).
- The output of `git diff --stat` and `git diff`.
- The path or content of the latest agent-check log.

If the verifier returns `verdict: fail`, fix the cited issue. If
`uncertain`, surface it to the user — do not silently dismiss.

## Step 7 — Final report

When done, tell the user:
- What changed (one sentence per file).
- What you verified (Layer A pass; Layer B verdict if invoked).
- What you did NOT verify (e.g. "did not run the app in browser").

Keep the report under 6 lines unless the task was large.

## Escape hatches

- For hard tasks where you expect single-shot to fail, suggest the user run
  `/cc-task <description>` instead — that runs Best-of-N parallel candidates.
- For tasks the harness can't validate (UI changes, integration tests
  needing real services), say so explicitly and suggest a manual check.
