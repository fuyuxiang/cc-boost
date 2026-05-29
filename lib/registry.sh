#!/usr/bin/env bash
# Model capability registry. Picks executor / verifier / summarizer / fallback
# from the providers a user has actually configured (env keys), and persists
# the choice to .cc-boost/config.json.
#
# Design goals:
#   - Cross-provider verifier when possible (error de-correlation).
#   - User can override anything via .cc-boost/config.json.
#   - No code changes needed to add a new provider — extend the table here.

# shellcheck disable=SC2034

# Each row: id|provider|family|tier|env_var|default_model|anthropic_compat
# tier ∈ exec,verify,fast,longctx,strong
# anthropic_compat = 1 if the provider exposes Claude-Code-compatible
# Anthropic endpoints (so it can be the default executor for Claude Code).
CC_MODEL_TABLE=$(cat <<'EOF'
minimax-m27|minimax|minimax|exec,verify,strong|MINIMAX_API_KEY|MiniMax-M2.7|1
minimax-m27-fast|minimax|minimax|fast,verify|MINIMAX_API_KEY|MiniMax-M2.7-highspeed|1
glm-5|zai|glm|exec,verify,strong|ZAI_API_KEY|glm-5|1
glm-5-air|zai|glm|fast,verify|ZAI_API_KEY|glm-5-air|1
kimi-k2|moonshot|kimi|exec,longctx,strong|MOONSHOT_API_KEY|kimi-k2|1
kimi-turbo|moonshot|kimi|fast,verify|MOONSHOT_API_KEY|kimi-turbo|1
deepseek-v4|deepseek|deepseek|exec,strong|DEEPSEEK_API_KEY|deepseek-v4|0
deepseek-chat|deepseek|deepseek|fast,verify|DEEPSEEK_API_KEY|deepseek-chat|0
qwen3-coder|dashscope|qwen|exec,strong|DASHSCOPE_API_KEY|qwen3-coder|0
qwen3-turbo|dashscope|qwen|fast,verify|DASHSCOPE_API_KEY|qwen3-turbo|0
claude-opus-47|anthropic|claude|exec,strong,verify|ANTHROPIC_API_KEY|claude-opus-4-7|1
claude-sonnet-46|anthropic|claude|exec,fast,verify|ANTHROPIC_API_KEY|claude-sonnet-4-6|1
claude-haiku-45|anthropic|claude|fast,verify|ANTHROPIC_API_KEY|claude-haiku-4-5|1
EOF
)

# Generic verifier endpoint. This is the preferred Layer B configuration:
# users set one OpenAI API compatible endpoint instead of learning provider-
# specific environment variable names.
#
# Required:
#   CC_BOOST_VERIFIER_BASE_URL=https://your-provider-or-gateway/v1
#   CC_BOOST_VERIFIER_API_KEY=...
#   CC_BOOST_VERIFIER_MODEL=...
#
# Optional:
#   CC_BOOST_VERIFIER_PROTOCOL=openai_chat   (default)
#   CC_BOOST_VERIFIER_FAMILY=glm             (used only for cross-family hints)
cc_generic_verifier_configured() {
  [[ -n "${CC_BOOST_VERIFIER_BASE_URL:-}" \
    && -n "${CC_BOOST_VERIFIER_API_KEY:-}" \
    && -n "${CC_BOOST_VERIFIER_MODEL:-}" ]]
}

cc_generic_verifier_role() {
  local family="${CC_BOOST_VERIFIER_FAMILY:-external}"
  jq -n \
    --arg id "cc-boost-verifier" \
    --arg p "cc-boost-verifier" \
    --arg f "$family" \
    --arg m "${CC_BOOST_VERIFIER_MODEL:-}" \
    --arg protocol "${CC_BOOST_VERIFIER_PROTOCOL:-openai_chat}" \
    --arg base_url "${CC_BOOST_VERIFIER_BASE_URL:-}" \
    '{id:$id, provider:$p, family:$f, model:$m,
      protocol:$protocol, base_url:$base_url,
      api_key_env:"CC_BOOST_VERIFIER_API_KEY"}'
}

# Provider endpoint table — legacy convenience presets used by run-verifier.sh
# when an older config only contains provider/model. New configs should persist
# protocol/base_url/api_key_env explicitly under .verifier.
# Row: provider|protocol|base_url|env_var
#   protocol = openai_chat | anthropic_messages
#   base_url is the chat/messages endpoint root; default model path is appended
#     by run-verifier.sh per protocol.
# For routers and self-hosted endpoints, prefer the generic
# CC_BOOST_VERIFIER_BASE_URL flow above.
CC_PROVIDER_TABLE=$(cat <<'EOF'
minimax|openai_chat|https://api.minimaxi.com/v1|MINIMAX_API_KEY
zai|openai_chat|https://api.z.ai/api/paas/v4|ZAI_API_KEY
moonshot|openai_chat|https://api.moonshot.cn/v1|MOONSHOT_API_KEY
deepseek|openai_chat|https://api.deepseek.com/v1|DEEPSEEK_API_KEY
dashscope|openai_chat|https://dashscope.aliyuncs.com/compatible-mode/v1|DASHSCOPE_API_KEY
anthropic|anthropic_messages|https://api.anthropic.com/v1|ANTHROPIC_API_KEY
EOF
)

# Look up provider endpoint. Echoes "protocol|base_url|env_var" or empty.
# Honors CC_BOOST_<PROVIDER>_BASE_URL override.
cc_provider_endpoint() {
  local want="$1"
  if [[ "$want" == "cc-boost-verifier" || "$want" == "openai-compatible" ]]; then
    local protocol="${CC_BOOST_VERIFIER_PROTOCOL:-openai_chat}"
    local base_url="${CC_BOOST_VERIFIER_BASE_URL:-}"
    [[ -n "$base_url" ]] || return 1
    echo "$protocol|$base_url|CC_BOOST_VERIFIER_API_KEY"
    return 0
  fi
  while IFS='|' read -r provider protocol base_url env_var; do
    [[ -z "$provider" || "$provider" =~ ^# ]] && continue
    if [[ "$provider" == "$want" ]]; then
      local override_var="CC_BOOST_$(echo "$provider" | tr '[:lower:]' '[:upper:]')_BASE_URL"
      local override="${!override_var:-}"
      [[ -n "$override" ]] && base_url="$override"
      echo "$protocol|$base_url|$env_var"
      return 0
    fi
  done <<< "$CC_PROVIDER_TABLE"
  return 1
}

# List ids whose tier list contains $1 AND env var is set.
cc_models_for_tier() {
  local tier="$1"
  while IFS='|' read -r id provider family tiers env_var model anthropic_compat; do
    [[ -z "$id" || "$id" =~ ^# ]] && continue
    [[ ",$tiers," == *",$tier,"* ]] || continue
    [[ -n "${!env_var:-}" ]] || continue
    echo "$id|$provider|$family|$model|$anthropic_compat"
  done <<< "$CC_MODEL_TABLE"
}

# Pick a verifier whose family differs from the executor's family.
# Falls back to same family (still better than nothing).
cc_pick_cross_family_verifier() {
  local exec_family="$1"
  if cc_generic_verifier_configured; then
    local generic_family="${CC_BOOST_VERIFIER_FAMILY:-external}"
    echo "cc-boost-verifier|cc-boost-verifier|$generic_family|$CC_BOOST_VERIFIER_MODEL"
    return 0
  fi
  local primary="" fallback=""
  while IFS='|' read -r id provider family tiers env_var model anthropic_compat; do
    [[ -z "$id" || "$id" =~ ^# ]] && continue
    [[ ",$tiers," == *",verify,"* ]] || continue
    [[ -n "${!env_var:-}" ]] || continue
    if [[ "$family" != "$exec_family" && -z "$primary" ]]; then
      primary="$id|$provider|$family|$model"
    fi
    if [[ -z "$fallback" ]]; then
      fallback="$id|$provider|$family|$model"
    fi
  done <<< "$CC_MODEL_TABLE"
  echo "${primary:-$fallback}"
}

# Probe which provider env vars exist; emit JSON {provider:{env:...,present:bool,model:...}}.
cc_probe_providers() {
  jq -n --argjson rows "$(
    : # build array
    {
      echo '['
      first=1
      generic_present="false"; cc_generic_verifier_configured && generic_present="true"
      jq -n \
        --arg id "cc-boost-verifier" \
        --arg provider "cc-boost-verifier" \
        --arg family "${CC_BOOST_VERIFIER_FAMILY:-external}" \
        --arg env "CC_BOOST_VERIFIER_API_KEY" \
        --argjson present "$generic_present" \
        --arg model "${CC_BOOST_VERIFIER_MODEL:-}" \
        --arg protocol "${CC_BOOST_VERIFIER_PROTOCOL:-openai_chat}" \
        --arg base_url "${CC_BOOST_VERIFIER_BASE_URL:-}" \
        '{id:$id, provider:$provider, family:$family, env:$env,
          present:$present, model:$model, tiers:"verify",
          protocol:$protocol, base_url:$base_url,
          api_format:"OpenAI /v1/chat/completions compatible",
          anthropic_compat:false}'
      first=0
      while IFS='|' read -r id provider family tiers env_var model anthropic_compat; do
        [[ -z "$id" || "$id" =~ ^# ]] && continue
        present="false"; [[ -n "${!env_var:-}" ]] && present="true"
        if (( first )); then first=0; else echo ','; fi
        jq -n \
          --arg id "$id" --arg provider "$provider" --arg family "$family" \
          --arg env "$env_var" --argjson present "$present" \
          --arg model "$model" --arg tiers "$tiers" \
          --argjson anthropic_compat "$anthropic_compat" \
          '{id:$id, provider:$provider, family:$family, env:$env, present:$present, model:$model, tiers:$tiers, anthropic_compat:($anthropic_compat==1)}'
      done <<< "$CC_MODEL_TABLE"
      echo ']'
    }
  )" '$rows'
}

# Resolve roles given the providers currently available.
# Echoes JSON: {"executor":..., "verifier":..., "summarizer":..., "fallback":..., "longctx":...}
# Each role is null or {id,provider,family,model}.
cc_resolve_roles() {
  local exec_id exec_provider exec_family exec_model
  local choice
  choice="$(cc_models_for_tier exec | head -n1)"
  if [[ -z "$choice" ]]; then
    local v_json="null"
    if cc_generic_verifier_configured; then
      v_json="$(cc_generic_verifier_role)"
    fi
    jq -n --argjson v "$v_json" \
      '{executor:null, verifier:$v, summarizer:null, fallback:null, longctx:null}'
    return
  fi
  IFS='|' read -r exec_id exec_provider exec_family exec_model _ <<< "$choice"

  local verifier_choice
  verifier_choice="$(cc_pick_cross_family_verifier "$exec_family")"
  local v_id v_provider v_family v_model v_json="null"
  if [[ -n "$verifier_choice" ]]; then
    IFS='|' read -r v_id v_provider v_family v_model <<< "$verifier_choice"
    if [[ "$v_provider" == "cc-boost-verifier" ]]; then
      v_json="$(cc_generic_verifier_role)"
    else
      v_json="$(jq -n --arg id "$v_id" --arg p "$v_provider" --arg f "$v_family" --arg m "$v_model" \
        '{id:$id, provider:$p, family:$f, model:$m}')"
    fi
  fi

  local summarizer_choice s_json="null"
  summarizer_choice="$(cc_models_for_tier fast | head -n1)"
  if [[ -n "$summarizer_choice" ]]; then
    IFS='|' read -r s_id s_provider s_family s_model _ <<< "$summarizer_choice"
    s_json="$(jq -n --arg id "$s_id" --arg p "$s_provider" --arg f "$s_family" --arg m "$s_model" \
      '{id:$id, provider:$p, family:$f, model:$m}')"
  fi

  local longctx_choice l_json="null"
  longctx_choice="$(cc_models_for_tier longctx | head -n1)"
  if [[ -n "$longctx_choice" ]]; then
    IFS='|' read -r l_id l_provider l_family l_model _ <<< "$longctx_choice"
    l_json="$(jq -n --arg id "$l_id" --arg p "$l_provider" --arg f "$l_family" --arg m "$l_model" \
      '{id:$id, provider:$p, family:$f, model:$m}')"
  fi

  local fallback_choice fb_json="null"
  fallback_choice="$(cc_models_for_tier strong | head -n1)"
  if [[ -n "$fallback_choice" ]]; then
    IFS='|' read -r fb_id fb_provider fb_family fb_model _ <<< "$fallback_choice"
    fb_json="$(jq -n --arg id "$fb_id" --arg p "$fb_provider" --arg f "$fb_family" --arg m "$fb_model" \
      '{id:$id, provider:$p, family:$f, model:$m}')"
  fi

  local exec_json
  exec_json="$(jq -n --arg id "$exec_id" --arg p "$exec_provider" --arg f "$exec_family" --arg m "$exec_model" \
    '{id:$id, provider:$p, family:$f, model:$m}')"

  jq -n \
    --argjson e "$exec_json" --argjson v "$v_json" --argjson s "$s_json" \
    --argjson f "$fb_json" --argjson l "$l_json" \
    '{executor:$e, verifier:$v, summarizer:$s, fallback:$f, longctx:$l}'
}
