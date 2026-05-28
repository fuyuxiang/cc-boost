---
description: Initialize cc-boost in the current project — detect language, install agent-check.sh, write CLAUDE.md harness rules, and probe available providers to assign executor / verifier / fallback roles.
allowed-tools: Bash, Read, Write, Edit
argument-hint: "[--force]"
---

You are running cc-boost's `/cc-init` setup. Your job is to bring the current
project to a state where the verifier-gated harness can operate. Be fast and
deterministic. Do not ask the user questions — infer everything from the repo.

## Steps (run in order; report at the end, not after each step)

### 1. Detect project type
Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/cc-init-detect.sh"` and capture the
JSON output. Fields: `project_type`, `agent_check_template`, `package_manager`.

### 2. Install agent-check.sh
If `scripts/agent-check.sh` already exists in the project AND the user did
NOT pass `--force`, leave it alone. Otherwise:
- `mkdir -p scripts`
- Copy the template returned in step 1 (one of node/python/go/rust/generic)
  from `${CLAUDE_PLUGIN_ROOT}/templates/agent-check/<lang>.sh` to
  `scripts/agent-check.sh`.
- `chmod +x scripts/agent-check.sh`.

### 3. Probe provider env vars
Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/cc-init-probe.sh"`. It emits the
resolved role assignment as JSON.

### 4. Write `.cc-boost/config.json`
Use the resolved-roles JSON from step 3. Include:
```json
{
  "enabled": true,
  "executor":  { "id":"...","provider":"...","family":"...","model":"..." },
  "verifier":  { "id":"...","provider":"...","family":"...","model":"...",
                 "enabled": true,
                 "min_files": 1,
                 "min_lines": 20,
                 "uncertain_action": "allow",
                 "cache_ttl_days": 7 },
  "summarizer":{ "id":"...","provider":"...","family":"...","model":"..." },
  "fallback":  { "id":"...","provider":"...","family":"...","model":"..." },
  "longctx":   { "id":"...","provider":"...","family":"...","model":"..." },
  "verify":    { "throttle_seconds": 8 },
  "final_gate":{ "max_blocks": 3 },
  "best_of_n": { "default_n": 2, "budget": "medium" }
}
```
The `verifier.enabled` flag should default to `true` only if a cross-family
verifier is available (executor.family != verifier.family); otherwise set
`verifier.enabled: false` so we don't fall back to same-model self-review.

If no provider env var is set at all, step 3 will return null roles. In that
case still proceed: write a config with `enabled: true` and
`verifier.enabled: false`, and use a placeholder executor block
(`{"id":"unknown","provider":"","family":"","model":""}`). The Layer A path
(agent-check + failure ledger + lessons) works without any key. The user can
later export a verifier key and rerun `/cc-doctor` to flip Layer B on.

`verifier.min_files` / `min_lines` define when a diff is considered
non-trivial enough to invoke Layer B. `uncertain_action` is `"allow"` or
`"block"` — what to do when the verifier returns `verdict=uncertain`.
`cache_ttl_days` controls how long a passing verdict for a given diff hash
suppresses re-verification.

### 5. Update CLAUDE.md
Add or refresh a controlled block in `CLAUDE.md` (create the file if absent).
The block is bounded by these markers; only the lines BETWEEN them may be
rewritten. Everything outside must be preserved verbatim.

```
<!-- cc-boost:start -->
... managed content ...
<!-- cc-boost:end -->
```

The managed content is the file
`${CLAUDE_PLUGIN_ROOT}/templates/CLAUDE-block.md`. Inline-substitute the
following placeholders before writing:
  - `{{EXECUTOR}}` → the executor model id
  - `{{VERIFIER}}` → the verifier model id (or "none")
  - `{{PROJECT_TYPE}}` → from step 1

### 6. Create the .cc-boost/ folder
```
.cc-boost/
  config.json          # written in step 4
  failures.jsonl       # touch empty file
  state/               # mkdir, runtime caches
  lessons.md           # touch with a stub heading
```

### 7. Append cache dirs to `.gitignore`
If `.gitignore` exists and does not already mention them, append these
lines (cc-boost's runtime caches — should not be committed):

```
.cc-boost/state/
.cc-boost/worktrees/
.cc-boost/bench/
```

Do NOT gitignore `.cc-boost/failures.jsonl` or `.cc-boost/lessons.md` —
those are valuable team artifacts.

### 8. Final report
Print a short summary table. Adapt the executor / verifier rows to the
resolved roles — when a key is missing, mark the role as disabled rather
than fabricating a model name.

```
cc-boost initialized
  Project type   : node
  Agent check    : scripts/agent-check.sh ✓
  Executor       : MiniMax-M2.7 (minimax)         # or "(no provider key — Layer A only)"
  Verifier       : glm-5 (zai)        ← cross-family ✓
                   # or "disabled — set a non-Claude provider key to enable Layer B"
  Summarizer     : MiniMax-M2.7-highspeed (minimax)
  Long context   : kimi-k2 (moonshot)
  CLAUDE.md      : controlled block updated
  Failures DB    : .cc-boost/failures.jsonl
Run /cc-doctor to verify hooks fire correctly.
```

## Rules
- Never overwrite user-authored sections of CLAUDE.md.
- Never change package.json / pyproject.toml / Cargo.toml.
- If `--force` is in arguments, overwrite scripts/agent-check.sh too.
- Never abort because provider keys are missing. Layer A runs offline; the
  config is written with `verifier.enabled: false` and the report tells the
  user how to unlock Layer B later.
