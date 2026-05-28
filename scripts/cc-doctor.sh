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

# Cross-family verifier check (this is the diff-from-other-tools advantage).
exec_family="$(echo "$roles_json" | jq -r '.executor.family // ""')"
ver_family="$(echo "$roles_json"  | jq -r '.verifier.family // ""')"
xfamily="false"
if [[ -n "$exec_family" && -n "$ver_family" && "$exec_family" != "$ver_family" ]]; then
  xfamily="true"
fi

# Verifier endpoint resolution — surface base_url + key state per the
# provider table so users can spot misconfig fast.
ver_provider="$(echo "$roles_json" | jq -r '.verifier.provider // ""')"
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

jq -n \
  --argjson roles "$roles_json" \
  --argjson probe "$probe_json" \
  --argjson ver_endpoint "$ver_endpoint_json" \
  --arg cfg_ok "$cfg_ok" --arg cfg_err "$cfg_err" \
  --arg ac_ok "$ac_ok"   --arg ac_err "$ac_err" \
  --arg hooks_ok "$hooks_ok" --arg hook_err "$hook_err" \
  --arg git_ok "$git_ok" --arg git_err "$git_err" \
  --argjson ledger_count "$ledger_count" \
  --arg xfamily "$xfamily" \
  '{
    config:   {ok:($cfg_ok=="true"), error:$cfg_err},
    agent_check: {ok:($ac_ok=="true"), error:$ac_err},
    hooks:    {ok:($hooks_ok=="true"), error:$hook_err},
    git_repo: {ok:($git_ok=="true"), error:$git_err},
    ledger:   {entries:$ledger_count},
    cross_family_verifier: ($xfamily=="true"),
    verifier_endpoint: $ver_endpoint,
    roles:    $roles,
    providers:$probe
  }'
