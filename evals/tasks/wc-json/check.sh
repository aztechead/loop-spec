#!/usr/bin/env bash
cd "$(dirname "$0")"
if python3 -m unittest discover -s tests >/dev/null 2>&1; then echo "CHECK existing_tests_pass PASS"; else echo "CHECK existing_tests_pass FAIL"; fi
out="$(python3 wc_tool.py --json sample.txt 2>&1)"
if python3 - "$out" <<'PY' 2>/dev/null; then echo "CHECK json_flag_works PASS"; else echo "CHECK json_flag_works FAIL output: ${out:0:120}"; fi
import json, sys
lines = [l for l in sys.argv[1].splitlines() if l.strip()]
objs = [json.loads(l) for l in lines]
assert len(objs) == 1, objs
o = objs[0]
assert set(o) >= {"path", "lines", "words", "chars"}, o
assert o["lines"] == 2 and o["words"] == 4, o
PY
text="$(python3 wc_tool.py sample.txt 2>&1)"
if [[ "$text" == *"sample.txt"* && "$text" != *"{"* ]]; then echo "CHECK text_output_unchanged PASS"; else echo "CHECK text_output_unchanged FAIL"; fi
if grep -rq "json" tests/ 2>/dev/null; then echo "CHECK json_test_added PASS"; else echo "CHECK json_test_added FAIL no test mentions json"; fi
