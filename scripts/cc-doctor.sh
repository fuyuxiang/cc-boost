#!/usr/bin/env bash
# Backend for /cc-doctor. Emits JSON diagnostics.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"
# shellcheck source=/dev/null
source "$LIB_DIR/common.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/registry.sh"

PROJECT_DIR="$(cc_project_dir)"
CFG="$(cc_config_path)"
LEDGER="$(cc_failures_path)"
AGENT_CHECK="$(cc_agent_check)"

cfg_ok="false"; cfg_err=""
if [[ -f "$CFG" ]]; then
  if jq -e . "$CFG" >/dev/null 2>&1; then
    cfg_ok="true"
  else
    cfg_err="config.json 存在但不是合法 JSON"
  fi
else
  cfg_err="未找到 —— 请运行 /cc-init"
fi

ac_ok="false"; ac_err=""
if [[ -x "$AGENT_CHECK" ]]; then
  ac_ok="true"
else
  if [[ -f "$AGENT_CHECK" ]]; then
    ac_err="存在但不可执行 —— chmod +x scripts/agent-check.sh"
  else
    ac_err="缺失 —— 请运行 /cc-init"
  fi
fi

ledger_count=0
if [[ -f "$LEDGER" ]]; then
  ledger_count="$(wc -l < "$LEDGER" | tr -d ' ')"
fi

probe_json="$(cc_probe_providers)"
roles_json="$(cc_resolve_roles)"

# Read the currently-installed verifier config separately from the env-derived
# role resolver. /cc-doctor must diagnose the config that hooks actually use,
# not only the roles that would be chosen by a fresh /cc-init.
cfg_executor_family=""
cfg_ver_enabled="false"
cfg_ver_provider=""
cfg_ver_family=""
cfg_ver_model=""
if [[ "$cfg_ok" == "true" ]]; then
  cfg_executor_family="$(jq -r '.executor.family // ""' "$CFG" 2>/dev/null)"
  cfg_ver_enabled="$(jq -r '.verifier.enabled // false' "$CFG" 2>/dev/null)"
  cfg_ver_provider="$(jq -r '.verifier.provider // ""' "$CFG" 2>/dev/null)"
  cfg_ver_family="$(jq -r '.verifier.family // ""' "$CFG" 2>/dev/null)"
  cfg_ver_model="$(jq -r '.verifier.model // ""' "$CFG" 2>/dev/null)"
fi

# Hook + script presence. Hooks come from the plugin install but we still
# check the file presence — a corrupt install or chmod glitch is the kind
# of thing /cc-doctor exists to catch.
hooks_ok="true"; hook_err=""
for f in \
    verify-after-edit.sh final-gate.sh inject-lessons.sh session-bootstrap.sh \
    diff-classify.sh run-verifier.sh \
    cc-task-setup.sh cc-task-evaluate.sh cc-task-apply.sh \
    summarize-failure.sh; do
  [[ -x "$SCRIPT_DIR/$f" ]] || { hooks_ok="false"; hook_err="$f 缺失或不可执行"; break; }
done

# Project is a git repo? /cc-task and the verifier diff path require it.
git_ok="false"; git_err=""
if ( cd "$PROJECT_DIR" && git rev-parse --git-dir >/dev/null 2>&1 ); then
  git_ok="true"
else
  git_err="项目不是 git 仓库 —— /cc-task 与 verifier diff 流程不可用"
fi

# Cross-family verifier checks:
#   cross_family_verifier = actual installed config state used by hooks.
#   available_cross_family_verifier = what the current env could support if the
#     user refreshes config with /cc-init or /cc-budget.
exec_family="$(echo "$roles_json" | jq -r '.executor.family // ""')"
ver_family="$(echo "$roles_json"  | jq -r '.verifier.family // ""')"
available_xfamily="false"
if [[ -n "$exec_family" && -n "$ver_family" && "$exec_family" != "$ver_family" ]]; then
  available_xfamily="true"
fi

configured_xfamily="false"
if [[ "$cfg_ver_enabled" == "true" && -n "$cfg_executor_family" && -n "$cfg_ver_family" && "$cfg_executor_family" != "$cfg_ver_family" ]]; then
  configured_xfamily="true"
fi

# Verifier endpoint resolution — surface base_url + key state per the
# provider table so users can spot misconfig fast. Prefer the configured
# provider because that is what run-verifier.sh will call.
ver_provider="$cfg_ver_provider"
if [[ -z "$ver_provider" ]]; then
  ver_provider="$(echo "$roles_json" | jq -r '.verifier.provider // ""')"
fi
ver_endpoint_json="null"
if [[ -n "$ver_provider" ]]; then
  ep="$(cc_provider_endpoint "$ver_provider" 2>/dev/null || true)"
  if [[ -n "$ep" ]]; then
    IFS='|' read -r v_proto v_base v_envvar <<< "$ep"
    v_keypresent="false"; [[ -n "${!v_envvar:-}" ]] && v_keypresent="true"
    ver_endpoint_json="$(jq -n \
      --arg provider "$ver_provider" --arg protocol "$v_proto" \
      --arg base_url "$v_base" --arg env "$v_envvar" \
      --arg present "$v_keypresent" \
      '{provider:$provider, protocol:$protocol, base_url:$base_url, env:$env, key_present:($present=="true")}')"
  fi
fi

config_verifier_json="$(jq -n \
  --arg enabled "$cfg_ver_enabled" \
  --arg provider "$cfg_ver_provider" \
  --arg family "$cfg_ver_family" \
  --arg model "$cfg_ver_model" \
  '{enabled:($enabled=="true"), provider:$provider, family:$family, model:$model}')"

jq -n \
  --argjson roles "$roles_json" \
  --argjson probe "$probe_json" \
  --argjson ver_endpoint "$ver_endpoint_json" \
  --argjson config_verifier "$config_verifier_json" \
  --arg cfg_ok "$cfg_ok" --arg cfg_err "$cfg_err" \
  --arg ac_ok "$ac_ok"   --arg ac_err "$ac_err" \
  --arg hooks_ok "$hooks_ok" --arg hook_err "$hook_err" \
  --arg git_ok "$git_ok" --arg git_err "$git_err" \
  --argjson ledger_count "$ledger_count" \
  --arg xfamily "$configured_xfamily" \
  --arg available_xfamily "$available_xfamily" \
  '{
    config:   {ok:($cfg_ok=="true"), error:$cfg_err},
    agent_check: {ok:($ac_ok=="true"), error:$ac_err},
    hooks:    {ok:($hooks_ok=="true"), error:$hook_err},
    git_repo: {ok:($git_ok=="true"), error:$git_err},
    ledger:   {entries:$ledger_count},
    cross_family_verifier: ($xfamily=="true"),
    available_cross_family_verifier: ($available_xfamily=="true"),
    config_verifier: $config_verifier,
    verifier_endpoint: $ver_endpoint,
    roles:    $roles,
    providers:$probe
  }'
