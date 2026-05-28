#!/usr/bin/env bash
# Build the /cc-bench fixture. We ship a small set of canonical tasks
# (bugs in tiny self-contained files) so the bench is hermetic.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"
# shellcheck source=/dev/null
source "$LIB_DIR/common.sh"

RUN_ID="$(date -u +%Y-%m-%dT%H-%MZ)"
ROOT="$(cc_boost_dir)/bench/$RUN_ID"
mkdir -p "$ROOT"

# Task 1 — Python: off-by-one in a paginator.
mkdir -p "$ROOT/task-01-paginator"
cat > "$ROOT/task-01-paginator/paginate.py" <<'PY'
def paginate(items, page, per_page):
    start = page * per_page
    end = start + per_page
    return items[start:end]
PY
cat > "$ROOT/task-01-paginator/test_paginate.py" <<'PY'
import unittest
from paginate import paginate

class PaginateTest(unittest.TestCase):
    def test_first_page(self):
        self.assertEqual(paginate(list(range(10)), 1, 3), [0, 1, 2])

    def test_second_page(self):
        self.assertEqual(paginate(list(range(10)), 2, 3), [3, 4, 5])
PY
cat > "$ROOT/task-01-paginator/task.md" <<'MD'
The paginate() function is supposed to use 1-indexed page numbers, but it
treats page as 0-indexed. Fix it so page=1 returns the first per_page items.
MD
cat > "$ROOT/task-01-paginator/oracle.json" <<'JSON'
{ "must_pass": ["python -m unittest -q"], "max_diff_lines": 5 }
JSON

# Task 2 — JavaScript: mutation bug in shallow copy.
mkdir -p "$ROOT/task-02-shallowcopy"
cat > "$ROOT/task-02-shallowcopy/package.json" <<'JSON'
{ "type": "module" }
JSON
cat > "$ROOT/task-02-shallowcopy/clone.js" <<'JS'
export function cloneUser(u) {
  return { ...u };
}
JS
cat > "$ROOT/task-02-shallowcopy/clone.test.js" <<'JS'
import test from "node:test";
import assert from "node:assert/strict";
import { cloneUser } from "./clone.js";

test("does not share tags array", () => {
  const a = { name: "x", tags: ["a"] };
  const b = cloneUser(a);
  b.tags.push("b");
  assert.deepEqual(a.tags, ["a"]);
});
JS
cat > "$ROOT/task-02-shallowcopy/task.md" <<'MD'
cloneUser() shallow-copies the object, so `tags` is shared. Make a deep
enough copy that mutating the clone's tags does not affect the source.
MD
cat > "$ROOT/task-02-shallowcopy/oracle.json" <<'JSON'
{ "must_pass": ["node --test"], "max_diff_lines": 6 }
JSON

# Task 3 — JavaScript: counter reports the wrong value.
mkdir -p "$ROOT/task-03-counter"
cat > "$ROOT/task-03-counter/package.json" <<'JSON'
{ "type": "module" }
JSON
cat > "$ROOT/task-03-counter/counter.js" <<'JS'
export class Counter {
  constructor() {
    this.n = 0;
  }

  inc() {
    this.n += 1;
  }

  value() {
    return this.n - 1;
  }
}
JS
cat > "$ROOT/task-03-counter/counter.test.js" <<'JS'
import test from "node:test";
import assert from "node:assert/strict";
import { Counter } from "./counter.js";

test("reports the number of increments", () => {
  const c = new Counter();
  c.inc();
  c.inc();
  assert.equal(c.value(), 2);
});
JS
cat > "$ROOT/task-03-counter/task.md" <<'MD'
Counter.value() is supposed to return the number of times inc() has been
called, but it currently reports one too few. Fix it without changing the
public API.
MD
cat > "$ROOT/task-03-counter/oracle.json" <<'JSON'
{ "must_pass": ["node --test"], "max_diff_lines": 6 }
JSON

# Task 4 — Python: regex misses Unicode.
mkdir -p "$ROOT/task-04-slug"
cat > "$ROOT/task-04-slug/slug.py" <<'PY'
import re
def slugify(s):
    return re.sub(r"[^a-zA-Z0-9]+", "-", s).strip("-").lower()
PY
cat > "$ROOT/task-04-slug/test_slug.py" <<'PY'
import unittest
from slug import slugify

class SlugTest(unittest.TestCase):
    def test_ascii(self):
        self.assertEqual(slugify("Hello World!"), "hello-world")

    def test_unicode_letter(self):
        # German umlaut should be preserved as a slug character, not stripped.
        self.assertEqual(slugify("Über Café"), "über-café")
PY
cat > "$ROOT/task-04-slug/task.md" <<'MD'
slugify() drops non-ASCII letters. Update the regex so Unicode letters
and digits are preserved (use the \w-with-Unicode-flag approach or an
explicit category test).
MD
cat > "$ROOT/task-04-slug/oracle.json" <<'JSON'
{ "must_pass": ["python -m unittest -q"], "max_diff_lines": 4 }
JSON

# Task 5 — JavaScript: dead-code elimination broke an export.
mkdir -p "$ROOT/task-05-export"
cat > "$ROOT/task-05-export/package.json" <<'JSON'
{ "type": "module" }
JSON
cat > "$ROOT/task-05-export/api.js" <<'JS'
function _internal() { return 1 }
export const VERSION = "1.0.0";
JS
cat > "$ROOT/task-05-export/api.test.js" <<'JS'
import test from "node:test";
import assert from "node:assert/strict";
import { VERSION, getInternal } from "./api.js";

test("exposes internal", () => {
  assert.equal(getInternal(), 1);
  assert.equal(VERSION, "1.0.0");
});
JS
cat > "$ROOT/task-05-export/task.md" <<'MD'
The test imports `getInternal` from ./api.js but it is not exported. Add an
exported function `getInternal` that returns what _internal returns.
Do not remove _internal or VERSION.
MD
cat > "$ROOT/task-05-export/oracle.json" <<'JSON'
{ "must_pass": ["node --test"], "max_diff_lines": 3 }
JSON

# Manifest
cat > "$ROOT/manifest.json" <<JSON
{
  "run_id": "$RUN_ID",
  "tasks": [
    "task-01-paginator",
    "task-02-shallowcopy",
    "task-03-counter",
    "task-04-slug",
    "task-05-export"
  ]
}
JSON

echo "$ROOT"
