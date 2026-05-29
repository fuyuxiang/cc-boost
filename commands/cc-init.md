---
description: Initialize cc-boost in the current project — detect language, install hidden agent-check, write local harness config, and probe available providers to assign executor / verifier / fallback roles.
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

### 2. Install `.cc-boost/agent-check.sh`
If `.cc-boost/agent-check.sh` already exists in the project AND the user did
NOT pass `--force`, leave it alone. Otherwise:
- `mkdir -p .cc-boost`
- Copy the template returned in step 1 (one of node/python/go/rust/generic)
  from `${CLAUDE_PLUGIN_ROOT}/templates/agent-check/<lang>.sh` to
  `.cc-boost/agent-check.sh`.
- `chmod +x .cc-boost/agent-check.sh`.

### 3. Probe verifier env vars
Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/cc-init-probe.sh"`. It emits the
resolved role assignment as JSON.

Preferred Layer B verifier setup is a generic OpenAI API compatible endpoint:

```bash
export CC_BOOST_VERIFIER_BASE_URL="https://your-provider-or-gateway/v1"
export CC_BOOST_VERIFIER_API_KEY="your key"
export CC_BOOST_VERIFIER_MODEL="glm-5"
```

`CC_BOOST_VERIFIER_PROTOCOL` is optional and defaults to `openai_chat`, which
means OpenAI API format: `POST <base_url>/chat/completions`.

### 4. Write `.cc-boost/config.json`
Use the resolved-roles JSON from step 3. Include:
```json
{
  "enabled": true,
  "executor":  { "id":"...","provider":"...","family":"...","model":"..." },
  "verifier":  { "id":"...","provider":"...","family":"...","model":"...",
                 "protocol": "openai_chat",
                 "base_url": "https://your-provider-or-gateway/v1",
                 "api_key_env": "CC_BOOST_VERIFIER_API_KEY",
                 "enabled": "auto",
                 "min_files": 1,
                 "min_lines": 20,
                 "uncertain_action": "allow",
                 "cache_ttl_days": 7 },
  "summarizer":{ "id":"...","provider":"...","family":"...","model":"..." },
  "fallback":  { "id":"...","provider":"...","family":"...","model":"..." },
  "longctx":   { "id":"...","provider":"...","family":"...","model":"..." },
  "verify":    { "throttle_seconds": 8 },
  "final_gate":{ "max_blocks": 3 },
  "quality":   { "mode": "light",
                 "regression_only": true,
                 "preflight": true,
                 "full_check_risk": "high" },
  "best_of_n": { "default_n": 2, "budget": "medium" }
}
```
The `verifier.enabled` flag is tri-state:
- `"auto"` means enable Layer B when `CC_BOOST_VERIFIER_BASE_URL`,
  `CC_BOOST_VERIFIER_API_KEY`, and `CC_BOOST_VERIFIER_MODEL` are all present.
- `true` forces verifier on if the endpoint can resolve.
- `false` forces verifier off.

New configs should prefer `"auto"` so a user can enable verifier later by
exporting the three env vars without editing `.cc-boost/config.json`.

If no verifier env var is set at all, step 3 may return null roles. In that
case still proceed: write a config with `enabled: true` and
`verifier.enabled: "auto"`, and use a placeholder executor block
(`{"id":"unknown","provider":"","family":"","model":""}`). The Layer A path
(agent-check + failure ledger + lessons) works without any key. The final
report must show a Chinese verifier reminder with the exact OpenAI API format
exports so the user knows how to enable Layer B later.

`verifier.min_files` / `min_lines` define when a diff is considered
non-trivial enough to invoke Layer B. `uncertain_action` is `"allow"` or
`"block"` — what to do when the verifier returns `verdict=uncertain`.
`cache_ttl_days` controls how long a passing verdict for a given diff hash
suppresses re-verification.
`quality.mode: "light"` means cc-boost defaults to regression-only gating:
existing baseline failures are recorded but not treated as mandatory fixes
for unrelated tasks. `quality.preflight` enables deterministic write guards
for high-risk tool usage.

### 5. Capture the initial quality baseline
Run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/baseline-capture.sh"
```

This writes `.cc-boost/runtime/baseline.json`. If the project is already green
it records `status:"pass"`; if not, it records the first deterministic-check
failure fingerprint so later hooks can distinguish pre-existing red CI from
new regressions.

### 6. Write local harness instructions
Write `.cc-boost/CLAUDE.md` from
`${CLAUDE_PLUGIN_ROOT}/templates/CLAUDE-block.md`. Inline-substitute the
following placeholders before writing:
  - `{{EXECUTOR}}` → the executor model id
  - `{{VERIFIER}}` → the verifier model id (or "none")
  - `{{PROJECT_TYPE}}` → from step 1

Do not edit the project's root `CLAUDE.md` by default. SessionStart injects the
active rules from the plugin, and the local `.cc-boost/CLAUDE.md` is an ignored
audit copy.

### 7. Create the .cc-boost/ folder
```
.cc-boost/
  agent-check.sh       # written in step 2
  config.json          # written in step 4
  CLAUDE.md            # written in step 6
  runtime/
    baseline.json      # written in step 5
    failures.jsonl     # touch empty file
    lessons.md         # touch with a stub heading
    state/             # runtime caches
    worktrees/         # /cc-task candidates
    bench/             # /cc-bench fixtures
    review-packets/    # verifier evidence packets
```

### 8. Ensure `.cc-boost/` is ignored by git
Create `.gitignore` if missing. If it does not already mention `.cc-boost/`,
append this line. cc-boost is local harness state and should not be committed:

```
.cc-boost/
```

If a team wants to share lessons, export a separate markdown file outside
`.cc-boost/` explicitly. Do not commit raw runtime ledgers by default; they can
contain internal paths, logs, or business terms.

### 9. Final report
Print a short summary table. Adapt the executor / verifier rows to the
resolved roles — when a key is missing, mark the role as disabled rather
than fabricating a model name.

```
cc-boost initialized
  Project type   : node
  Agent check    : .cc-boost/agent-check.sh ✓
  Executor       : MiniMax-M2.7 (minimax)         # or "(no executor provider key — Layer A only)"
  Verifier       : glm-5 (cc-boost-verifier, openai_chat) ← cross-family ✓
                   # or:
                   disabled
                   提醒：如需启用 Layer B verifier，请设置一个外部模型的
                   OpenAI API 格式接口。默认 protocol=openai_chat，
                   调用 POST <base_url>/chat/completions：
                     export CC_BOOST_VERIFIER_BASE_URL="https://your-provider-or-gateway/v1"
                     export CC_BOOST_VERIFIER_API_KEY="你的 key"
                     export CC_BOOST_VERIFIER_MODEL="glm-5"
  Summarizer     : MiniMax-M2.7-highspeed (minimax)
  Long context   : kimi-k2 (moonshot)
  Quality mode   : light (regression-only baseline captured)
  Harness rules  : .cc-boost/CLAUDE.md
  Runtime DB     : .cc-boost/runtime/failures.jsonl
Run /cc-doctor to verify hooks fire correctly.
```

## Rules
- Never overwrite the project's root CLAUDE.md by default.
- Never change package.json / pyproject.toml / Cargo.toml.
- If `--force` is in arguments, overwrite `.cc-boost/agent-check.sh` too.
- Never abort because provider keys are missing. Layer A runs offline; the
  config is written with `verifier.enabled: "auto"` and the report tells the
  user how to unlock Layer B later.
