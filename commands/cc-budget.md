---
description: Adjust cc-boost runtime settings — quality mode, Best-of-N count, verifier on/off, throttle, max-blocks. Persists changes to .cc-boost/config.json.
allowed-tools: Bash, Read, Edit
argument-hint: "[--mode=light|quality|ci] [--n=2|3] [--verifier=on|off] [--throttle=N] [--budget=low|medium|high] [--preflight=on|off]"
---

Update fields in `.cc-boost/config.json`. Map:

| Flag | Field |
|---|---|
| `--n=N`            | `best_of_n.default_n` |
| `--mode=light`     | `quality.mode = "light"`, `quality.regression_only = true` |
| `--mode=quality`   | `quality.mode = "quality"`, `quality.regression_only = true`, `verifier.enabled = "auto"` |
| `--mode=ci`        | `quality.mode = "ci"`, `quality.regression_only = false`, `verifier.enabled = true` |
| `--preflight=on/off` | `quality.preflight` |
| `--verifier=on/off`| `verifier.enabled` |
| `--throttle=N`     | `verify.throttle_seconds` |
| `--budget=low`     | `best_of_n.budget = "low"`, `verifier.enabled = false` |
| `--budget=medium`  | `best_of_n.budget = "medium"`, `verifier.enabled = "auto"` |
| `--budget=high`    | `best_of_n.budget = "high"`, `best_of_n.default_n = 3`, `verifier.enabled = true` |

After each edit, print the resulting config in a compact form. If a flag
contradicts the resolved roles (e.g. `--verifier=on` but no verifier API is
configured), refuse and tell the user in Chinese to set
`CC_BOOST_VERIFIER_BASE_URL`, `CC_BOOST_VERIFIER_API_KEY`, and
`CC_BOOST_VERIFIER_MODEL`. Also state that the default protocol is
`openai_chat`, meaning OpenAI API format:
`POST <base_url>/chat/completions`.
Use `verifier.enabled=false` only as an explicit opt-out; otherwise prefer
`"auto"` so setting the three env vars enables verifier without another config
edit.
