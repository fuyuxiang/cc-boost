#!/usr/bin/env bash
# Helper for /cc-init step 3: probe provider env vars and return resolved roles.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"
# shellcheck source=/dev/null
source "$LIB_DIR/common.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/registry.sh"

ROLES_JSON="$(cc_resolve_roles)"
PROBE_JSON="$(cc_probe_providers)"

# Decide whether to enable Layer B (cross-model verifier) by default.
exec_family="$(echo "$ROLES_JSON" | jq -r '.executor.family // ""')"
verif_family="$(echo "$ROLES_JSON" | jq -r '.verifier.family // ""')"
enable_verifier="false"
if [[ -n "$exec_family" && -n "$verif_family" && "$exec_family" != "$verif_family" ]]; then
  enable_verifier="true"
fi

jq -n \
  --argjson roles "$ROLES_JSON" \
  --argjson probe "$PROBE_JSON" \
  --arg enable_verifier "$enable_verifier" \
  '{roles:$roles, probe:$probe, enable_verifier:($enable_verifier=="true")}'
