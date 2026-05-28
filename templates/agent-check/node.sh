#!/usr/bin/env bash
# cc-boost agent-check (Node.js). Auto-installed by /cc-init.
# Run typecheck → lint → test, in that order. First failure short-circuits.
# Override behavior by editing this file; cc-boost won't re-overwrite it.
set -uo pipefail

PM=""
if [[ -f pnpm-lock.yaml ]]; then PM=pnpm
elif [[ -f yarn.lock ]];   then PM=yarn
elif [[ -f bun.lockb ]];    then PM=bun
elif [[ -f package-lock.json ]]; then PM=npm
else PM=npm
fi

run() {
  echo "::cc-boost::run $*"
  "$@"
}

has_script() {
  node -e "
    const p=require('./package.json').scripts||{};
    process.exit(p['$1']?0:1)
  " 2>/dev/null
}

if has_script typecheck; then
  run "$PM" run typecheck || exit 1
elif [[ -f tsconfig.json ]]; then
  if command -v npx >/dev/null 2>&1; then run npx --no-install tsc --noEmit || exit 1; fi
fi

if has_script lint; then
  run "$PM" run lint || exit 1
fi

if has_script test; then
  # Many test runners hang in interactive mode. Force CI flag.
  CI=1 run "$PM" test --silent --run 2>/dev/null \
    || CI=1 run "$PM" test --silent \
    || exit 1
fi

echo "::cc-boost::ok"
exit 0
