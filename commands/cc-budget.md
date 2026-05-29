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
| `--mode=quality`   | `quality.mode = "quality"`, `quality.regression_only = true`, `verifier.enabled = true if cross-family available` |
| `--mode=ci`        | `quality.mode = "ci"`, `quality.regression_only = false`, `verifier.enabled = true` |
| `--preflight=on/off` | `quality.preflight` |
| `--verifier=on/off`| `verifier.enabled` |
| `--throttle=N`     | `verify.throttle_seconds` |
| `--budget=low`     | `best_of_n.budget = "low"`, `verifier.enabled = false` |
| `--budget=medium`  | `best_of_n.budget = "medium"`, `verifier.enabled = true if cross-family available` |
| `--budget=high`    | `best_of_n.budget = "high"`, `best_of_n.default_n = 3`, `verifier.enabled = true` |

After each edit, print the resulting config in a compact form. If a flag
contradicts the resolved roles (e.g. `--verifier=on` but no verifier role
is configured), refuse and tell the user which env var they need.
