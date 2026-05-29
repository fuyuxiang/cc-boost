---
description: Run the cc-boost mini-benchmark. Solves a fixed set of small coding tasks against a local fixture repo three ways — bare model, harness-only, harness + Best-of-N — and prints a comparison table. Mode `bon` calls the real /cc-task pipeline; bare/harness use prompt-driven solves with deterministic oracle scoring.
allowed-tools: Bash, Read, Write, Agent
argument-hint: "[--tasks=N] [--budget=low|medium|high]"
---

You are running `/cc-bench`. Goal: produce a quantitative comparison on a
small fixed task set, using the user's currently-configured executor and
verifier. This is how cc-boost proves it actually helps on the user's
provider stack — they shouldn't trust marketing benchmarks.

## Procedure

1. Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/cc-bench-init.sh"`. This
   prepares a temporary fixture repo under `.cc-boost/runtime/bench/<run-id>/`
   containing N small bug-fix tasks (default N=5). Each task has:
   - Buggy source files
   - A failing test
   - A `task.md` describing what to fix
   - An `oracle.json` with `must_pass` commands and `max_diff_lines`

   The fixture root path is printed on stdout as the last line.

2. Each task is its own subdir. For EACH task and EACH mode, do this:

   ### Mode `bare`
   Spawn a `general-purpose` Agent with ONLY the `task.md` content as
   the prompt and the task subdir as cwd context. No CLAUDE.md harness
   block, no verifier hint. Time it. After the Agent returns, run:
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/cc-bench-oracle.sh" --task-dir=<path>`
   Parse the JSON: `.solved`, `.diff_lines`.

   ### Mode `harness`
   Same Agent type, but inject a copy of `templates/CLAUDE-block.md` at
   the top of the prompt as instructions. After the Agent returns, run
   the oracle.

   ### Mode `bon`
   Inside the task subdir, init a tiny git repo (`git init && git add -A
   && git commit -qm initial`) so /cc-task's worktree machinery works.
   Then drive the real cc-task pipeline DIRECTLY — do NOT just simulate
   /cc-task semantics:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}"/scripts/cc-task-setup.sh \
     --task="$(cat task.md)" --n=2 --budget=medium
   ```

   Spawn N `cc-boost-candidate` Agents per the manifest (parallel, single
   message — same as /cc-task). Then:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}"/scripts/cc-task-evaluate.sh --run-id=<id>
   "${CLAUDE_PLUGIN_ROOT}"/scripts/cc-task-apply.sh   --run-id=<id> --mode=apply
   ```

   Then run the oracle on the post-apply tree.

   If the user passed `--no-verifier`, also pass it to evaluate.

3. Measure for each (task, mode):
   - `solved` (oracle exit 0)
   - `diff_lines` (from oracle.json)
   - `wallclock_seconds` (date +%s before/after)
   - `tool_calls` (count Agent tool invocations within the mode)
   - For `bon`: also capture `verifier_verdict` from evaluation.json's
     winner row, if present.

4. Aggregate into a markdown table. The column "Mean diff" should reflect
   only solved runs (otherwise it's noise from failed attempts).

```
cc-boost /cc-bench results
  Executor : MiniMax-M2.7 (minimax)
  Verifier : glm-5 (zai) — cross-family
  Tasks    : 5
  Run id   : 2026-05-28T16-52Z

| Mode    | Solved | Mean diff (solved) | Mean tool calls | Median wallclock |
|---------|--------|--------------------|-----------------|-------------------|
| bare    | 2/5    | 47                 | 14              | 38s               |
| harness | 4/5    | 19                 | 11              | 51s               |
| bon     | 5/5    | 12                 | 23              | 78s               |
```

5. For each task that bare failed but harness OR bon solved, show the
   failure that the harness caught (read from `.cc-boost/runtime/failures.jsonl`
   for the run-id). This is the user-facing proof that the verifier is
   doing work.

## Hard rules

- Never run the bench against the user's real working tree. Use
  `.cc-boost/runtime/bench/<run-id>/` exclusively.
- After the run, leave the fixture in place but write a note at the bottom
  of the report: "Fixture preserved at <path>. Delete with `rm -rf` if
  not needed."
- For `bon`, if `cc-task-apply.sh` exits 2 (no acceptable winner), record
  the task as `solved=false` for `bon` and continue — don't abort the run.
- If the user has only one provider configured, `bon` mode degenerates to
  same-family multi-sampling. Note this in the report — it understates the
  benefit of cross-model BoN.
