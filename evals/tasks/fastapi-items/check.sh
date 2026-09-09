#!/usr/bin/env bash
# Acceptance for fastapi-items. Prints one `CHECK <name> PASS|FAIL <note>` line per criterion.
# The fixture container ships no Python 3.14: finding or installing one is part of the
# task, so this script only looks for what the cycle left behind (a python3.14 on PATH,
# or one uv knows about) and builds a throwaway venv from the project's own pyproject.
cd "$(dirname "$0")"
if grep -Eq 'requires-python *= *">= *3\.14' pyproject.toml 2>/dev/null; then
  echo "CHECK pyproject_requires_314 PASS"; else echo "CHECK pyproject_requires_314 FAIL no requires-python >=3.14 in pyproject.toml"; fi
py="$(command -v python3.14 2>/dev/null || uv python find 3.14 2>/dev/null || true)"
ver="$("$py" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || true)"
if [[ "$ver" == "3.14" ]]; then echo "CHECK python314_available PASS $py"; else echo "CHECK python314_available FAIL no 3.14 interpreter (got '${ver:-none}')"; fi
venv=".check-venv"; rm -rf "$venv"
if [[ "$ver" == "3.14" ]] && "$py" -m venv "$venv" >/dev/null 2>&1 \
   && "$venv/bin/python" -m pip install -q . httpx pytest >/dev/null 2>&1; then
  echo "CHECK deps_install PASS"; else echo "CHECK deps_install FAIL pip install . httpx pytest under 3.14 failed"; fi
run="$venv/bin/python"
[[ -x "$run" ]] || run=python3
out="$("$run" - <<'PY' 2>&1
from fastapi.testclient import TestClient
from main import app
c = TestClient(app)
r = c.post("/items", json={"name": "apple", "quantity": 3})
assert r.status_code in (200, 201), r.status_code
r = c.get("/items")
assert r.status_code == 200, r.status_code
items = r.json()
assert any(i.get("name") == "apple" and i.get("quantity") == 3 for i in items), items
r = c.post("/items", json={"name": "pear", "quantity": "nope"})
assert r.status_code == 422, r.status_code
r = c.get("/items")
assert [i["name"] for i in r.json()] == ["apple"], r.json()
print("ok")
PY
)"
if [[ "$out" == *ok ]]; then echo "CHECK post_then_get PASS"; else echo "CHECK post_then_get FAIL $(tail -1 <<<"$out")"; fi
if "$run" -m pytest -q >/dev/null 2>&1; then echo "CHECK unit_tests_pass PASS"; else echo "CHECK unit_tests_pass FAIL"; fi
n="$(ls test*.py tests/test*.py 2>/dev/null | wc -l)"
if (( n > 0 )); then echo "CHECK tests_exist PASS"; else echo "CHECK tests_exist FAIL no test files"; fi
if grep -qi "uvicorn\|fastapi" README.md 2>/dev/null && ! grep -q Placeholder README.md; then echo "CHECK readme_written PASS"; else echo "CHECK readme_written FAIL"; fi
rm -rf "$venv"
