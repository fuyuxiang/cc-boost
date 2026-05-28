#!/usr/bin/env bash
# cc-boost agent-check (Python).
set -uo pipefail

run() { echo "::cc-boost::run $*"; "$@"; }

if command -v ruff >/dev/null 2>&1; then
  run ruff check . || exit 1
elif command -v flake8 >/dev/null 2>&1; then
  run flake8 . || exit 1
fi

if command -v mypy >/dev/null 2>&1 && [[ -f mypy.ini || -f pyproject.toml ]]; then
  run mypy . || true   # Type errors are warnings only by default.
fi

if command -v pytest >/dev/null 2>&1; then
  run pytest -x -q || exit 1
elif [[ -f manage.py ]]; then
  run python manage.py test --noinput || exit 1
fi

echo "::cc-boost::ok"
exit 0
