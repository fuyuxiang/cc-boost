---
description: Diagnose cc-boost — verify verifier API settings, role assignment, hook firing, agent-check script, and emit a health report.
allowed-tools: Bash, Read
argument-hint: ""
---

You are running cc-boost's `/cc-doctor`. Print a health report.

## Steps

1. Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/cc-doctor.sh"`. It prints a JSON
   diagnostic report covering:
   - Generic verifier env vars (`CC_BOOST_VERIFIER_BASE_URL`,
     `CC_BOOST_VERIFIER_API_KEY`, `CC_BOOST_VERIFIER_MODEL`) and legacy
     provider env vars (set / unset)
   - Resolved role assignment (executor, verifier, summarizer, fallback, longctx)
   - The verifier's resolved HTTP endpoint (provider, protocol, base_url, env),
     whether the API key for it is present, and the API format hint
   - Whether `.cc-boost/agent-check.sh` exists and is executable
   - Whether `.cc-boost/config.json` exists and is parseable
   - Whether `.cc-boost/runtime/baseline.json` exists and is parseable
   - The active quality mode (`quality.mode`, `regression_only`, `preflight`)
   - The verifier currently configured in `.cc-boost/config.json`
   - Whether the project is a git repo (required by /cc-task and the verifier)
   - Whether the failure ledger is writable
   - Whether all plugin-side scripts exist (hooks + cc-task helpers + verifier)
   - The size of `.cc-boost/runtime/failures.jsonl` and number of entries

2. Translate the JSON into a human-readable status block. For each role, show
   `id (provider)` plus a tick or cross. Cross-family verifier should be
   highlighted positively — that's the lift mechanism. Show the verifier
   endpoint's `base_url` (truncate to host + first path segment), `protocol`,
   `api_key_env`, and a tick if `key_present`. Use Chinese for the verifier
   reminder.

   Distinguish three states for the verifier row:
   - **enabled & cross-family** — green tick, this is the target state.
   - **auto & env complete** — green tick if the configured/effective verifier
     is external; explain that `verifier.enabled=auto` is enabled because the
     three `CC_BOOST_VERIFIER_*` env vars are present.
   - **disabled because verifier env is missing** — neutral info line, NOT an
     error. Phrase it in Chinese:
     "Layer B verifier 未启用。需要一个外部模型的 OpenAI API 格式接口；
     默认 protocol=openai_chat，调用 POST <base_url>/chat/completions。设置：
     `export CC_BOOST_VERIFIER_BASE_URL=\"https://your-provider-or-gateway/v1\"`,
     `export CC_BOOST_VERIFIER_API_KEY=\"你的 key\"`,
     `export CC_BOOST_VERIFIER_MODEL=\"glm-5\"`。"
   - **same-family verifier** — warning, because the lift mechanism depends on
     cross-family review. Tell the user to set `CC_BOOST_VERIFIER_FAMILY` when
     they know the verifier model family.
   - **misconfigured** — config says `verifier.enabled: true` but the key is
     missing, the endpoint can't be resolved, or the configured verifier is not
     cross-family. THIS is an error.

3. If any structural step is broken (`config`, `baseline`, `agent_check`, `hooks`,
   `git_repo`), print the single command the user should run to fix it
   (e.g. `chmod +x .cc-boost/agent-check.sh`, `/cc-init --force`, `git init`).
   A missing verifier key is not a broken state when `verifier.enabled=false`
   or `verifier.enabled=auto`; surface it as the neutral Chinese setup reminder,
   not as a fix-me error.

Keep the output to ≤30 lines.
