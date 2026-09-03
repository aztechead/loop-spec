#!/usr/bin/env bash
# Tests for lib/doc-deps.sh -- imports-intersect-manifest probe + PLAN doc-grounding gate.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/lib/doc-deps.sh"
PASS=0
FAIL=0

check() {
  local name="$1" cond="$2"
  if [[ "$cond" == "1" ]]; then PASS=$((PASS+1)); echo "PASS: $name"
  else FAIL=$((FAIL+1)); echo "FAIL: $name"; fi
}

WORK="${TMPDIR:-/tmp}/doc-deps-test.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/src"
cd "$WORK"

# ─── Fixture repo: python + js manifests and touched files ──────────────────
printf 'google-adk>=2.7\nrequests==2.31\nunused-dep\n' > requirements.txt
cat > pyproject.toml <<'EOF'
[project]
name = "myproj"
dependencies = ["fastapi>=0.100", "pydantic==2.5"]
EOF
cat > package.json <<'EOF'
{"dependencies": {"react": "^18", "@google/genai": "1.0.0"}, "devDependencies": {"vitest": "^1"}}
EOF
cat > src/a.py <<'EOF'
import os, sys
from google.adk.agents import LlmAgent
import requests
import myproj.util
from fastapi import FastAPI
EOF
cat > src/b.ts <<'EOF'
import React from 'react';
import { helper } from './local';
import { GoogleGenAI } from '@google/genai/web';
EOF

# ─── scan: intersection, not the whole manifest ─────────────────────────────
out="$(bash "$LIB" scan src/a.py)"
check "scan finds namespace-package dep (google.adk -> google-adk)" \
  "$([[ "$out" == *google-adk* ]] && echo 1 || echo 0)"
check "scan finds pyproject dep (fastapi)" "$([[ "$out" == *fastapi* ]] && echo 1 || echo 0)"
check "scan excludes stdlib (os)" "$([[ "$out" != *ANSWER=*os,* && "$out" != *,os* ]] && echo 1 || echo 0)"
check "scan excludes declared-but-unimported (pydantic)" "$([[ "$out" != *pydantic* ]] && echo 1 || echo 0)"
check "scan excludes the project's own name (myproj)" "$([[ "$out" != *myproj* ]] && echo 1 || echo 0)"

out_ts="$(bash "$LIB" scan src/b.ts)"
check "scan finds scoped js dep (@google/genai)" "$([[ "$out_ts" == *@google/genai* ]] && echo 1 || echo 0)"
check "scan skips relative js import (./local)" "$([[ "$out_ts" != *local* ]] && echo 1 || echo 0)"

# A probe never fails: unknown language and missing file both shrink to none.
out_none="$(bash "$LIB" scan src/missing.py; echo "rc=$?")"
check "scan of missing file answers none, exit 0" \
  "$([[ "$out_none" == *ANSWER=none* && "$out_none" == *rc=0* ]] && echo 1 || echo 0)"

# ─── scan: operator override outranks the tree ──────────────────────────────
out_ov="$(LOOP_SPEC_DOC_DEPS=alpha,beta bash "$LIB" scan src/a.py)"
check "override replaces the scan answer" "$([[ "$out_ov" == *ANSWER=alpha,beta* ]] && echo 1 || echo 0)"

# ─── gate: covered vs uncovered ─────────────────────────────────────────────
cat > tasks.json <<'EOF'
[{"id":"task-001","files":["src/a.py"]}]
EOF
cat > PLAN-covered.md <<'EOF'
# Plan

## Grounding

- EVID-001: google_adk 2.7 docs recommend LlmAgent with typed tool functions
- ASSUMPTION: requests GET semantics unchanged | verify: pip show requests
- ASSUMPTION: fastapi route decorators stable | verify: pip show fastapi
EOF
bash "$LIB" gate --tasks tasks.json --artifact PLAN-covered.md >/dev/null 2>&1
check "gate passes when every dep has a bullet (separator-insensitive match)" \
  "$([[ "$?" == "0" ]] && echo 1 || echo 0)"

cat > PLAN-uncovered.md <<'EOF'
# Plan

## Grounding

<!-- google-adk mentioned only here, in a comment: must not count -->
- ASSUMPTION: requests GET semantics unchanged | verify: pip show requests
- ASSUMPTION: fastapi route decorators stable | verify: pip show fastapi
EOF
out_gate="$(bash "$LIB" gate --tasks tasks.json --artifact PLAN-uncovered.md; echo "rc=$?")"
check "gate flags the uncovered dep, exit 1" \
  "$([[ "$out_gate" == *"FLAG"* && "$out_gate" == *google-adk* && "$out_gate" == *rc=1* ]] && echo 1 || echo 0)"
check "a dep named only inside an HTML comment is not coverage" \
  "$([[ "$out_gate" == *google-adk* ]] && echo 1 || echo 0)"

# ─── gate: fail-safe paths ──────────────────────────────────────────────────
out_missing="$(bash "$LIB" gate --tasks missing.json --artifact PLAN-covered.md; echo "rc=$?")"
check "gate with missing tasks.json is ok (the sidecar has its own gates)" \
  "$([[ "$out_missing" == *"doc-deps: ok"* && "$out_missing" == *rc=0* ]] && echo 1 || echo 0)"

out_off="$(LOOP_SPEC_DOC_DEPS=none bash "$LIB" gate --tasks tasks.json --artifact PLAN-uncovered.md; echo "rc=$?")"
check "override=none clears the gate" "$([[ "$out_off" == *rc=0* ]] && echo 1 || echo 0)"

cat > tasks-nodeps.json <<'EOF'
[{"id":"task-001","files":["docs/notes.md"]}]
EOF
out_nodeps="$(bash "$LIB" gate --tasks tasks-nodeps.json --artifact PLAN-uncovered.md; echo "rc=$?")"
check "gate with no third-party imports is ok" "$([[ "$out_nodeps" == *rc=0* ]] && echo 1 || echo 0)"

# ─── usage errors ───────────────────────────────────────────────────────────
bash "$LIB" scan >/dev/null 2>&1
check "scan with no files exits 2" "$([[ "$?" == "2" ]] && echo 1 || echo 0)"
bash "$LIB" bogus >/dev/null 2>&1
check "unknown mode exits 2" "$([[ "$?" == "2" ]] && echo 1 || echo 0)"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
