#!/usr/bin/env bash
# Tests for lib/feature-write.sh
set -euo pipefail

LIB="$(cd "$(dirname "$0")/../.." && pwd)/lib/feature-write.sh"
PASS=0
FAIL=0

check() {
  local name="$1"
  local expected="$2"
  local actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name (expected $expected, got $actual)"
    ((FAIL++)) || true
  fi
}

WORK="${TMPDIR:-/tmp}/loop-spec-feature-write.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/feat"

# Case A: write to fresh dir produces feature.json with correct content
bash "$LIB" "$WORK/feat" '{"slug":"foo","schemaVersion":1}' >/dev/null
got=$(jq -r '.slug' "$WORK/feat/feature.json" 2>/dev/null || echo MISSING)
check "A: fresh write creates feature.json with content" "foo" "$got"

# Case B: second write rotates current to .bak
bash "$LIB" "$WORK/feat" '{"slug":"bar","schemaVersion":1}' >/dev/null
got_curr=$(jq -r '.slug' "$WORK/feat/feature.json")
got_bak=$(jq -r '.slug' "$WORK/feat/feature.json.bak")
check "B: second write rotates current to .bak (current=bar)" "bar" "$got_curr"
check "B: second write rotates current to .bak (bak=foo)" "foo" "$got_bak"

# Case C: invalid JSON rejected, feature.json untouched
exit_code=0
bash "$LIB" "$WORK/feat" 'not json {{{' >/dev/null 2>&1 || exit_code=$?
check "C: invalid JSON rejected (exit 1)" "1" "$exit_code"
got_unchanged=$(jq -r '.slug' "$WORK/feat/feature.json")
check "C: feature.json unchanged after invalid input" "bar" "$got_unchanged"

# Case D: missing dir rejected
exit_code=0
bash "$LIB" "$WORK/missing" '{"x":1}' >/dev/null 2>&1 || exit_code=$?
check "D: missing dir rejected (exit 1)" "1" "$exit_code"

# Case E: wrong arg count rejected
exit_code=0
bash "$LIB" "$WORK/feat" >/dev/null 2>&1 || exit_code=$?
check "E: wrong arg count rejected (exit 1)" "1" "$exit_code"

# Case F: no .tmp file left behind after success
bash "$LIB" "$WORK/feat" '{"slug":"baz"}' >/dev/null
[[ -f "$WORK/feat/feature.json.tmp" ]] && tmp_present=yes || tmp_present=no
check "F: feature.json.tmp cleaned up after success" "no" "$tmp_present"

# ── set / append subcommands (regression: a field run misdiagnosed nested set
#    as "top-level only" and bypassed the script with raw jq) ──────────────────
bash "$LIB" "$WORK/feat" '{"slug":"baz","artifacts":{"patterns":null},"warnings":[]}' >/dev/null

# Case G: top-level set
bash "$LIB" set "$WORK/feat" currentPhase '"plan"' >/dev/null
check "G: top-level set" "plan" "$(jq -r '.currentPhase' "$WORK/feat/feature.json")"

# Case H: NESTED set (dot path into an object)
bash "$LIB" set "$WORK/feat" artifacts.patterns '"docs/PATTERNS.md"' >/dev/null
check "H: nested set writes through dot path" "docs/PATTERNS.md" \
  "$(jq -r '.artifacts.patterns' "$WORK/feat/feature.json")"

# Case H2: nested set creates missing intermediate objects
bash "$LIB" set "$WORK/feat" telemetry.dispatches '3' >/dev/null
check "H2: nested set creates intermediates" "3" \
  "$(jq -r '.telemetry.dispatches' "$WORK/feat/feature.json")"

# Case H3: set null and false (valid JSON values, not errors)
bash "$LIB" set "$WORK/feat" artifacts.patterns 'null' >/dev/null
check "H3: set null accepted" "null" "$(jq -r '.artifacts.patterns' "$WORK/feat/feature.json")"
bash "$LIB" set "$WORK/feat" autonomous 'false' >/dev/null
check "H3: set false accepted" "false" "$(jq -r '.autonomous' "$WORK/feat/feature.json")"

# Case I: append to an array, and to a null/missing path (becomes [v])
bash "$LIB" append "$WORK/feat" warnings '"w1"' >/dev/null
bash "$LIB" append "$WORK/feat" warnings '"w2"' >/dev/null
check "I: append grows array" '["w1","w2"]' "$(jq -c '.warnings' "$WORK/feat/feature.json")"
bash "$LIB" append "$WORK/feat" telemetry.events '"e1"' >/dev/null
check "I: append to missing path creates array" '["e1"]' \
  "$(jq -c '.telemetry.events' "$WORK/feat/feature.json")"

# Case J: append onto a non-array is refused, file untouched
exit_code=0
bash "$LIB" append "$WORK/feat" currentPhase '"x"' >/dev/null 2>&1 || exit_code=$?
check "J: append onto non-array rejected" "1" "$( [[ $exit_code -ne 0 ]] && echo 1 || echo 0 )"
check "J: file untouched after refusal" "plan" "$(jq -r '.currentPhase' "$WORK/feat/feature.json")"

# Case K: bare (unquoted) string value → clear error naming the quoting rule
err=$(bash "$LIB" set "$WORK/feat" artifacts.patterns docs/PATTERNS.md 2>&1 >/dev/null) && exit_code=0 || exit_code=$?
check "K: bare string value rejected (exit 1)" "1" "$exit_code"
check "K: error explains JSON quoting" "1" "$(grep -c 'JSON-quoted' <<<"$err")"
check "K: file untouched after bad value" "null" \
  "$(jq -r '.artifacts.patterns' "$WORK/feat/feature.json")"

# Case L: array-index path rejected with the array-limitation hint
err=$(bash "$LIB" set "$WORK/feat" 'workspace.repos[0]' '"x"' 2>&1 >/dev/null) && exit_code=0 || exit_code=$?
check "L: array-index dot_path rejected" "1" "$exit_code"
check "L: error names the limitation" "1" "$(grep -c 'array indices are not' <<<"$err")"

# Acknowledgment removes only the published prefix under the writer's lock.
bash "$LIB" "$WORK/feat" '{"slug":"ack","pendingRemediationTasks":[{"id":"a"},{"id":"b"}],"artifacts":{"tasks":"tasks.json"},"warnings":["keep"],"specApproval":{"digest":"immutable"}}' >/dev/null
ack='{"snapshot":[{"id":"a"}],"generation":null,"receipt":"first"}'
exit_code=0
bash "$LIB" ack-remediation "$WORK/feat" "$ack" >/dev/null 2>&1 || exit_code=$?
check "ack: exact prefix acknowledged" "0" "$exit_code"
check "ack: concurrent suffix remains" '[{"id":"b"}]' "$(jq -c '.pendingRemediationTasks' "$WORK/feat/feature.json")"
check "ack: unrelated artifacts retained" "tasks.json" "$(jq -r '.artifacts.tasks' "$WORK/feat/feature.json")"
check "ack: unrelated warnings retained" '["keep"]' "$(jq -c '.warnings' "$WORK/feat/feature.json")"
check "ack: approval unchanged" '{"digest":"immutable"}' "$(jq -c '.specApproval' "$WORK/feat/feature.json")"
before="$(cat "$WORK/feat/feature.json")"
exit_code=0
bash "$LIB" ack-remediation "$WORK/feat" "$ack" >/dev/null 2>&1 || exit_code=$?
check "ack: stale snapshot rejected" "1" "$exit_code"
check "ack: stale snapshot changes nothing" "$before" "$(cat "$WORK/feat/feature.json")"

exit_code=0
bash "$LIB" set "$WORK/feat" specApproval '{"digest":"changed"}' >/dev/null 2>&1 || exit_code=$?
check "ack: later writes still cannot change approval" "1" "$exit_code"
check "ack: rejected approval edit changes nothing" "$before" "$(cat "$WORK/feat/feature.json")"
printf '#!/usr/bin/env bash\necho "injected store persistence failure" >&2\nexit 2\n' > "$WORK/failing-store.sh"
chmod +x "$WORK/failing-store.sh"
exit_code=0
LOOP_SPEC_STORE="$WORK/failing-store.sh" bash "$LIB" set "$WORK/feat" slug '"locally-written"' >/dev/null 2>&1 || exit_code=$?
check "writer: store persistence failure remains exit 2" "2" "$exit_code"
check "writer: store failure retains the existing local-written contract" "locally-written" "$(jq -r '.slug' "$WORK/feat/feature.json")"

PYTHONPATH="$(dirname "$LIB")" python3 "$(dirname "$0")/feature-write-concurrency.py" "$LIB" || FAIL=$((FAIL + 1))

echo ""
PYTHONPATH="$(dirname "$LIB")" python3 - "$WORK" <<'PYTEST' || FAIL=$((FAIL + 1))
import copy, json, subprocess, sys
from pathlib import Path
from requirements import initialize_contract, reconcile_inventory
root = Path(__import__('requirements').__file__).parent
folder = Path(sys.argv[1]) / 'identity'
folder.mkdir()
owner = {'repository':'repo','feature':'fixture'}
c = initialize_contract(owner, 'v1')
i = {'version':1,'owner':owner,'requirements':[{'id':'GE-001','revision':'a'*64,'scenarios':[{'id':'SC-001'},{'id':'SC-002'}]}],'obligations':[]}
c = reconcile_inventory(c, i)
i['requirements'][0]['scenarios'].pop()
c = reconcile_inventory(c, i)
state = {'requirementsContract':c}
def write(args):
    return subprocess.run(['bash',str(root/'feature-write.sh')] + args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
assert write([str(folder),json.dumps(state)]).returncode == 0
assert write(['reconcile-inventory',str(folder),json.dumps(i)]).returncode == 0
original = (folder/'feature.json').read_bytes()
changes = [({}, 'removal')]
for key, value in [('owner',dict(owner,repository='other')),('format','legacy'),('version',True),('nextRequirementId',1),('retiredScenarios',{}),('issued',{}),('unknown',1)]:
    candidate = copy.deepcopy(state)
    candidate['requirementsContract'][key] = value
    changes.append((candidate,key))
for candidate, label in changes:
    result = write([str(folder),json.dumps(candidate)])
    assert result.returncode == 1, (label,result.stderr)
    assert (folder/'feature.json').read_bytes() == original
    if candidate:
        result = write(['set',str(folder),'requirementsContract',json.dumps(candidate['requirementsContract'])])
        assert result.returncode == 1, (label,result.stderr)
        assert (folder/'feature.json').read_bytes() == original
advanced = copy.deepcopy(state)
advanced['requirementsContract']['nextRequirementId'] = 9
advanced['requirementsContract']['issued']['GE-001']['nextScenarioId'] = 9
assert write([str(folder),json.dumps(advanced)]).returncode == 0
for path in [('nextRequirementId',), ('issued','GE-001','nextScenarioId')]:
    candidate = copy.deepcopy(advanced)
    target = candidate['requirementsContract']
    for key in path[:-1]:
        target = target[key]
    target[path[-1]] = 5
    original = (folder/'feature.json').read_bytes()
    for args in [[str(folder),json.dumps(candidate)],
                 ['set',str(folder),'requirementsContract',json.dumps(candidate['requirementsContract'])]]:
        result = write(args)
        assert result.returncode == 1, (path,result.stderr)
        assert 'history cannot roll back' in result.stderr, (path,result.stderr)
        assert (folder/'feature.json').read_bytes() == original
assert write(['reconcile-inventory',str(folder),json.dumps(dict(i, requirements=[]))]).returncode == 0
retired = json.loads((folder/'feature.json').read_text())
assert retired['requirementsContract']['retired'] == ['GE-001']
resurrected = copy.deepcopy(retired)
resurrected['requirementsContract']['retired'] = []
original = (folder/'feature.json').read_bytes()
for args in [[str(folder),json.dumps(resurrected)],
             ['set',str(folder),'requirementsContract.retired','[]'],
             ['reconcile-inventory',str(folder),json.dumps(i)]]:
    result = write(args)
    assert result.returncode == 1, result.stderr
    assert (folder/'feature.json').read_bytes() == original
print('PASS: writer rejects retired GE resurrection and independently valid counter rollback')
legacy = Path(sys.argv[1]) / 'legacy-identity'
legacy.mkdir()
(legacy/'feature.json').write_text('{"slug":"old"}')
for args in [[str(legacy),json.dumps(state)],['set',str(legacy),'requirementsContract',json.dumps(c)]]:
    assert write(args).returncode == 1
print('PASS: ordinary and replacement writes preserve identity histories and legacy boundary')
PYTEST

PYTHONPATH="$(dirname "$LIB")" python3 - "$WORK" "$LIB" <<'PYRACE' || FAIL=$((FAIL + 1))
import json, subprocess, sys, time
from pathlib import Path
from artifact_publication import capture_locked, locked_feature
folder = Path(sys.argv[1]) / 'publication-race'
folder.mkdir()
state = {'slug':'race','warnings':[],'artifacts':{'spec':'SPEC.md'},'artifactPublication':{'version':1,'generation':0,'evidenceEpoch':0,'migration':None,'participantsVersion':1}}
(folder/'feature.json').write_text(json.dumps(state))
(folder/'SPEC.md').write_text('before')
(folder/'publication-staging').mkdir()
(folder/'publication-staging/spec').write_text('after')
with locked_feature(folder):
    token = capture_locked(folder)
(folder/'token.json').write_text(json.dumps(token))
(folder/'manifest.json').write_text(json.dumps({'version':1,'files':[{'source':'publication-staging/spec','target':'spec'}],'updates':[{'path':'currentPhase','value':'plan'}]}))
script = """
import artifact_publication as a, subprocess, sys, time
from pathlib import Path
folder = Path(sys.argv[1])
original = subprocess.run
def guarded(command, *args, **kwargs):
    assert not any('feature-write' in str(part) and str(part).endswith(('.sh','.py')) for part in command), command
    return original(command, *args, **kwargs)
subprocess.run = guarded
def barrier(point):
    if point == 'staging':
        (folder/'ready').touch()
        deadline = time.monotonic() + 10
        while not (folder/'release').exists():
            assert time.monotonic() < deadline, 'barrier timeout'
            time.sleep(.01)
a.main(['publish','--feature-dir',str(folder),'--token',str(folder/'token.json'),'--manifest',str(folder/'manifest.json')], failure=barrier, allowed_updates={'currentPhase'})
"""
publisher = subprocess.Popen([sys.executable,'-c',script,str(folder)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
deadline = time.monotonic() + 10
while not (folder/'ready').exists():
    assert publisher.poll() is None, publisher.communicate()
    assert time.monotonic() < deadline
    time.sleep(.01)
writer = subprocess.Popen(['bash',sys.argv[2],'append',str(folder),'warnings','"concurrent"'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
(folder/'release').touch()
output, error = publisher.communicate(timeout=15)
assert publisher.returncode == 0, error
assert writer.communicate(timeout=15) == ('','') and writer.returncode == 0
state = json.loads((folder/'feature.json').read_text())
assert state['warnings'] == ['concurrent'] and state['currentPhase'] == 'plan'
assert state['artifactPublication']['generation'] == 2 and state['artifactPublication']['evidenceEpoch'] == 0
assert (folder/'SPEC.md').read_text() == 'after'
print('PASS: publication then queued ordinary writer completes without recursive acquisition or lost updates')
result = subprocess.run(['bash',sys.argv[2],'set',str(folder),'currentPhase','"execute"','--token',str(folder/'token.json')],capture_output=True,text=True)
assert result.returncode == 1 and state == json.loads((folder/'feature.json').read_text())
with locked_feature(folder):
    token = capture_locked(folder)
(folder/'token.json').write_text(json.dumps(token))
result = subprocess.run(['bash',sys.argv[2],'append',str(folder),'warnings','"own"','--token',str(folder/'token.json')],capture_output=True,text=True)
assert result.returncode == 0, result.stderr
assert json.loads(result.stdout)['generation'] == 3
print('PASS: explicit state tokens reject stale writes and refresh only their accepted write')
PYRACE

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
