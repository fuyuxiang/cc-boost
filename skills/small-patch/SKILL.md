---
description: Discipline for keeping patches small. Auto-load when the user requests a bug fix, single-file change, or any task that does not explicitly call for refactoring.
---

# Small-patch discipline

cc-boost's selection mechanism in /cc-task explicitly prefers smaller diffs
among verified candidates. The same preference applies to ordinary edits.
Small patches:

- Are easier for the cross-model verifier to judge accurately.
- Have fewer places for weak models to introduce regressions.
- Are easier for a human reviewer to approve.
- Reduce the cost of re-running agent-check.

## Targets

| Task type | Acceptable diff size |
|---|---|
| Typo / one-line bug | 1–3 lines |
| Single-function bug | 5–20 lines |
| Small feature | 20–80 lines |
| Cross-cutting change | "as small as possible, justified" |

If you are about to write a patch that exceeds the rough target, ask yourself
whether you are scope-creeping.

## Anti-patterns to avoid

- **Drive-by refactor.** Renaming things, extracting helpers, "cleaning up"
  imports while fixing an unrelated bug. Don't.
- **Defensive overcoding.** Adding null checks, try/except, type guards
  for situations that can't arise.
- **Dependency creep.** Adding a library to do something the project
  already does another way.
- **Comment inflation.** Adding multi-line comments to explain code that's
  already self-evident from names.
- **API parameterization.** Adding `options: { ... }` parameters in case
  someone might want to configure this later. They won't.

## When a big diff IS justified

You may write a large patch when:
- The user explicitly requested a refactor.
- The task is genuinely cross-cutting (e.g. renaming a public API).
- A small patch would require duplicating significant logic.

In those cases, *say so first* in your plan. Don't sneak it in.

## Heuristic check

Before submitting, look at `git diff --stat`. If the line count surprises
you, you probably added something the task didn't ask for. Remove it.
