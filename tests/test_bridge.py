#!/usr/bin/env python3
"""Self-checks for vim-ai-bridge pure logic. Run: python3 tests/test_bridge.py"""
import sys
sys.dont_write_bytecode = True
import importlib.machinery
import importlib.util
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
loader = importlib.machinery.SourceFileLoader("bridge", os.path.join(HERE, "..", "bin", "vim-ai-bridge"))
spec = importlib.util.spec_from_loader("bridge", loader)
b = importlib.util.module_from_spec(spec)
loader.exec_module(b)

cfg = b.load_config()

# changed ranges: insert, modify, delete
old = ["a", "b", "c", "d"]
assert b.changed_ranges(old, ["a", "X", "c", "d"]) == [(2, 2)]
assert b.changed_ranges(old, ["a", "b", "n1", "n2", "c", "d"]) == [(3, 4)]
assert b.changed_ranges(old, ["a", "d"]) == [(2, 2)]           # deletion -> line after gap
assert b.changed_ranges([], ["x", "y"]) == [(1, 2)]
assert b.changed_ranges(old, old) == []

# meaningful-change threshold ignores whitespace-only edits
assert not b.meaningful(["   ", "\t"], [(1, 2)], 3)
assert b.meaningful(["await x()"], [(1, 1)], 3)

# ignore patterns
for p in ["/p/node_modules/x/i.js", "/p/dist/a.js", "/p/app.min.js", "/p/.env", "/p/.env.local",
          "/p/package-lock.json", "/p/.git/config"]:
    assert b.is_ignored(p, cfg["ignore"]), p
for p in ["/p/src/worker.ts", "/p/app/main.py", "/p/environment.ts"]:
    assert not b.is_ignored(p, cfg["ignore"]), p

# validation: drops GOOD, bad lines, missing title; clamps; sorts by severity
raw = {"findings": [
    {"line": 3, "severity": "WARNING", "category": "PERFORMANCE", "title": "seq io", "message": "m"},
    {"line": 1, "severity": "ERROR", "category": "CORRECTNESS", "title": "bug", "message": "m", "end_line": 0},
    {"line": 99, "severity": "ERROR", "category": "CORRECTNESS", "title": "out of range", "message": "m"},
    {"line": 2, "severity": "GOOD", "category": "CORRECTNESS", "title": "nice", "message": "m"},
    {"line": "x", "severity": "ERROR", "title": "bad line"},
    {"line": 2, "severity": "INSIGHT", "category": "TESTS", "title": "", "message": "m"},
    "garbage",
]}
v = b.validate_findings(raw, 10, cfg, "/p/f.ts")
assert [f["title"] for f in v] == ["bug", "seq io"], v
assert v[0]["end_line"] == 1 and v[0]["file"] == "/p/f.ts"

# invalid model output must raise ValueError (caller recovers), never crash differently
for bad in ["not json", json.dumps({"is_error": True, "result": "boom"}), json.dumps({"result": "no json here"})]:
    try:
        b.parse_model_output(bad)
        raise AssertionError("expected ValueError")
    except ValueError:
        pass
try:
    b.validate_findings({"nope": 1}, 5, cfg, "f")
    raise AssertionError("expected ValueError")
except ValueError:
    pass
# structured_output preferred; fenced JSON in result tolerated
assert b.parse_model_output(json.dumps({"structured_output": {"findings": []}})) == {"findings": []}
assert b.parse_model_output(json.dumps({"result": "```json\n{\"findings\": []}\n```"})) == {"findings": []}

# context: small files are sent whole, large files only around changes
assert b.context_ranges(50, [(10, 12)], cfg) == [(1, 50)]
big = b.context_ranges(5000, [(2000, 2003)], cfg, 2001)
assert big[0][0] == 1 and any(a <= 2000 <= e for a, e in big) and big[-1][1] < 2200, big

print("bridge self-test: all passed")
