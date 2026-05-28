#!/usr/bin/env bash
# cc-boost agent-check (Go).
set -uo pipefail
run() { echo "::cc-boost::run $*"; "$@"; }

run go vet ./... || exit 1
run go build ./... || exit 1
run go test ./... || exit 1

echo "::cc-boost::ok"
exit 0
