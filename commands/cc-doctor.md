---
description: Diagnose cc-boost — verify provider keys, role assignment, hook firing, agent-check script, and emit a health report.
allowed-tools: Bash, Read
argument-hint: ""
---

You are running cc-boost's `/cc-doctor`. Print a health report.

## Steps

1. Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/cc-doctor.sh"`. It prints a JSON
   diagnostic report covering:
   - Each provider env var (set / unset)
   - Resolved role assignment (executor, verifier, summarizer, fallback, longctx)
   - The verifier's resolved HTTP endpoint (provider, protocol, base_url, env)
     and whether the API key for it is present
   - Whether `scripts/agent-check.sh` exists and is executable
   - Whether `.cc-boost/config.json` exists and is parseable
   - The verifier currently configured in `.cc-boost/config.json`
   - Whether the project is a git repo (required by /cc-task and the verifier)
   - Whether the failure ledger is writable
   - Whether all plugin-side scripts exist (hooks + cc-task helpers + verifier)
   - The size of `.cc-boost/failures.jsonl` and number of entries

2. Translate the JSON into a human-readable status block. For each role, show
   `id (provider)` plus a tick or cross. Cross-family verifier should be
   highlighted positively — that's the lift mechanism. Show the verifier
   endpoint's `base_url` (truncate to host + first path segment) and a tick
   if `key_present`.

   Distinguish three states for the verifier row:
   - **enabled & cross-family** — green tick, this is the target state.
   - **same-family or disabled because no second-family key is set** — neutral
     info line, NOT an error. Phrase it as "Layer B disabled — set a
     non-Claude provider key (e.g. `ZAI_API_KEY`, `MINIMAX_API_KEY`,
     `MOONSHOT_API_KEY`, `DEEPSEEK_API_KEY`, `DASHSCOPE_API_KEY`) and rerun
     `/cc-budget --verifier=on` to enable cross-family verification after
     exporting a second-family provider key."
   - **misconfigured** — config says `verifier.enabled: true` but the key is
     missing, the endpoint can't be resolved, or the configured verifier is not
     cross-family. THIS is an error.

3. If any structural step is broken (`config`, `agent_check`, `hooks`,
   `git_repo`), print the single command the user should run to fix it
   (e.g. `chmod +x scripts/agent-check.sh`, `/cc-init --force`, `git init`).
   A missing verifier key is not a broken state when `verifier.enabled=false`.
   Surface it as the neutral info line described above, not as a fix-me error.

Keep the output to ≤30 lines.
