#!/usr/bin/env bash
# cc-boost agent-check (Rust).
set -uo pipefail
run() { echo "::cc-boost::run $*"; "$@"; }

run cargo check --workspace --all-targets || exit 1
run cargo clippy --workspace --all-targets -- -D warnings || exit 1
run cargo test --workspace --quiet || exit 1

echo "::cc-boost::ok"
exit 0
