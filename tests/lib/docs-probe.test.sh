#!/usr/bin/env bash
# Tests for lib/docs-probe.sh -- current versions and docs from live sources, offline here.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/lib/docs-probe.sh"
PASS=0
FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then PASS=$((PASS+1)); echo "PASS: $name"
  else FAIL=$((FAIL+1)); echo "FAIL: $name (expected '$expected', got '$actual')"; fi
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/docs-probe-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
export LOOP_SPEC_DOCS_FIXTURES="$tmp/fixtures"; mkdir -p "$LOOP_SPEC_DOCS_FIXTURES" "$tmp/proj"
# A canned response is keyed the way the module keys a URL: sha1(url)[:16].
canned() { printf '%s' "$2" > "$LOOP_SPEC_DOCS_FIXTURES/$(printf '%s' "$1" | sha1sum | cut -c1-16)"; }

canned "https://pypi.org/pypi/fastlib/json" '{"info":{"version":"2.5.0","home_page":"","project_urls":{"Documentation":"https://fastlib.example/docs","Source":"https://github.com/acme/fastlib"},"description":"# fastlib\n\nRegistry readme."}}'
canned "https://pypi.org/pypi/fastlib/2.4.0/json" '{"info":{"version":"2.4.0","project_urls":{"Documentation":"https://fastlib.example/docs"},"description":"# fastlib 2.4\n\nold readme"}}'
canned "https://fastlib.example/docs/llms-full.txt" "$(printf '# fastlib\n\nIntro line.\n\n## Routing\n\nDeclare routes with @app.get.\nMore routing.\n\n## Testing\n\nUse TestClient from fastlib.testclient.\nCall client.get in a test.\n\n## Deploy\n\nRun with a server.\n')"
canned "https://registry.npmjs.org/leftpad" '{"dist-tags":{"latest":"9.1.0"},"homepage":"https://leftpad.example","repository":{"url":"git+https://github.com/acme/leftpad.git"},"readme":"# leftpad\n\nPads strings on the left to a given length, the registry copy."}'
canned "https://raw.githubusercontent.com/acme/leftpad/v9.1.0/README.md" "$(printf '# leftpad\n\n## Usage\n\nleftpad(str, len) pads str on the left until it is len characters long.\n')"
canned "https://endoflife.date/api/python.json" '[{"cycle":"3.14","latest":"3.14.7","latestReleaseDate":"2026-08-05"},{"cycle":"3.13","latest":"3.13.9"}]'

# --- latest ---
check "latest: pypi answers one line" "version=2.5.0 source=https://pypi.org/pypi/fastlib/json ecosystem=pypi" \
  "$(bash "$LIB" latest fastlib --ecosystem pypi)"
check "latest: a runtime resolves through the release tracker" "version=3.14.7 source=https://endoflife.date/api/python.json ecosystem=runtime" \
  "$(bash "$LIB" latest python --ecosystem runtime)"
rc=0; out="$(bash "$LIB" latest nosuchthing --ecosystem pypi 2>&1)" || rc=$?
check "latest: no answer is unverified, exit 1" "1" "$rc"
check "latest: the unverified line names what was tried" "1" "$(grep -c '^version=unverified reason=.*pypi.org/pypi/nosuchthing/json' <<<"$out")"

# --- ecosystem from the manifest, else every row ---
printf '[project]\nname = "x"\n' > "$tmp/proj/pyproject.toml"
check "manifest picks pypi without a flag" "pypi" "$(bash "$LIB" resolve fastlib --dir "$tmp/proj" | jq -r .ecosystem)"
check "no manifest tries every row and reports the one that answered" "npm" "$(bash "$LIB" resolve leftpad --dir "$tmp" | jq -r .ecosystem)"
check "resolve carries docs and repo" "https://fastlib.example/docs https://github.com/acme/fastlib" \
  "$(bash "$LIB" resolve fastlib --ecosystem pypi | jq -r '"\(.docs) \(.repo)"')"
check "resolve at a pinned version" "2.4.0" "$(bash "$LIB" resolve fastlib --ecosystem pypi --version 2.4.0 | jq -r .version)"
check "npm repository url is normalized" "https://github.com/acme/leftpad" "$(bash "$LIB" resolve leftpad --ecosystem npm | jq -r .repo)"

# --- docs ---
out="$(bash "$LIB" docs fastlib --ecosystem pypi --topic testing)"
check "docs: header names the version and the llms.txt source" "docs: fastlib@2.5.0 source=https://fastlib.example/docs/llms-full.txt" "$(head -1 <<<"$out")"
check "docs: the topic section is returned" "1" "$(grep -c 'Use TestClient from fastlib.testclient' <<<"$out")"
check "docs: unrelated sections are left out" "0" "$(grep -c 'Declare routes' <<<"$out")"
out="$(bash "$LIB" docs fastlib --ecosystem pypi --max-lines 3)"
check "docs: no topic returns the head, capped" "4" "$(wc -l <<<"$out" | tr -d ' ')"
out="$(bash "$LIB" docs leftpad --ecosystem npm --topic usage)"
check "docs: README at the version tag when no llms.txt" "docs: leftpad@9.1.0 source=https://raw.githubusercontent.com/acme/leftpad/v9.1.0/README.md" "$(head -1 <<<"$out")"
rm -f "$LOOP_SPEC_DOCS_FIXTURES/$(printf '%s' "https://raw.githubusercontent.com/acme/leftpad/v9.1.0/README.md" | sha1sum | cut -c1-16)"
out="$(bash "$LIB" docs leftpad --ecosystem npm)"
check "docs: registry readme when README is unreachable" "docs: leftpad@9.1.0 source=https://registry.npmjs.org/leftpad" "$(head -1 <<<"$out")"
canned "https://pypi.org/pypi/bare/json" '{"info":{"version":"1.0.0","project_urls":{}}}'
rc=0; out="$(bash "$LIB" docs bare --ecosystem pypi)" || rc=$?
check "docs: nothing answers is unverified, exit 1" "1" "$rc"
check "docs: the unverified line says what was tried" "1" "$(grep -c '^docs: unverified reason=' <<<"$out")"

# --- bad invocation ---
rc=0; bash "$LIB" latest >/dev/null 2>&1 || rc=$?
check "missing name exits 2" "2" "$rc"
rc=0; bash "$LIB" fetch x >/dev/null 2>&1 || rc=$?
check "unknown subcommand exits 2" "2" "$rc"
rc=0; bash "$LIB" latest x --ecosystem maven >/dev/null 2>&1 || rc=$?
check "unknown ecosystem exits 1 with the known list" "1" "$rc"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
