#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/lib/artifact-sink.sh"
PASS=0
FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"; FAIL=$((FAIL + 1))
  fi
}

git -C "$WORK" init -q -b main
git -C "$WORK" -c user.name=Test -c user.email=test@example.com commit --allow-empty -qm base
base="$(git -C "$WORK" rev-parse HEAD)"
git -C "$WORK" checkout -qb feat/demo
feature="$WORK/.loop-spec/features/demo"
docs="$WORK/docs/loop-spec/features/demo"
mkdir -p "$feature" "$docs"
printf '# Spec\n' > "$docs/SPEC.md"
jq -n --arg base "$base" '{schemaVersion:7,slug:"demo",baseSha:$base,currentPhase:"deliver",
  artifacts:{spec:"docs/loop-spec/features/demo/SPEC.md"}}' > "$feature/feature.json"
git -C "$WORK" add .
git -C "$WORK" -c user.name=Test -c user.email=test@example.com commit -qm artifacts

check "default keeps artifacts inline" "inline" \
  "$(bash "$LIB" store "$feature" "$WORK")"
check "default leaves source artifact" "1" "$([[ -f "$docs/SPEC.md" ]] && echo 1 || echo 0)"

store="$WORK-store"
result="$(LOOP_SPEC_ARTIFACTS_IN_PR=0 LOOP_SPEC_ARTIFACT_DIR="$store" \
  bash "$LIB" store "$feature" "$WORK")"
destination="${result#stored:}"
check "store mode reports destination" "1" "$([[ "$result" == stored:* ]] && echo 1 || echo 0)"
check "artifact copied to store" "1" "$([[ -f "$destination/artifacts/SPEC.md" ]] && echo 1 || echo 0)"
check "feature state copied to store" "1" "$([[ -f "$destination/state/feature.json" ]] && echo 1 || echo 0)"
check "manifest records source head" "1" \
  "$(jq -e '.artifactsInPr == false and (.sourceHead | length > 0)' "$destination/manifest.json" >/dev/null && echo 1 || echo 0)"
check "source artifacts removed from candidate" "0" "$([[ -e "$docs/SPEC.md" ]] && echo 1 || echo 0)"
check "feature records store mode" "store" "$(jq -r '.artifactSink.mode' "$feature/feature.json")"
check "artifact deletion is staged" "1" \
  "$(git -C "$WORK" diff --cached --name-only | grep -qx 'docs/loop-spec/features/demo/SPEC.md' && echo 1 || echo 0)"
check "store retry is idempotent" "$result" \
  "$(LOOP_SPEC_ARTIFACTS_IN_PR=0 LOOP_SPEC_ARTIFACT_DIR="$store" \
    bash "$LIB" store "$feature" "$WORK")"

PYTHONPATH="$ROOT/lib" python3 - <<'PY'
import json, os, subprocess, tempfile
from pathlib import Path
from unittest import TestCase
import artifact_sink
from artifact_publication import capture_locked, locked_feature
from feature_write import write_operation

check = TestCase()
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)/'repo'
    root.mkdir()
    def git(*args):
        return subprocess.check_output(['git','-C',str(root),*args]).decode().strip()
    git('init','-q','-b','main')
    git('config','user.name','Test')
    git('config','user.email','test@example.com')
    docs = root/'docs/loop-spec/features/demo'
    docs.mkdir(parents=True)
    (docs/'kept.md').write_text('baseline')
    git('add','.')
    git('commit','-qm','baseline')
    base = git('rev-parse','HEAD')
    (docs/'kept.md').write_text('candidate')
    (docs/'SPEC.md').write_text('new requirement')
    git('add','.')
    git('commit','-qm','candidate')
    feature = root/'.loop-spec/features/demo'
    feature.mkdir(parents=True)
    state = {'schemaVersion':7,'slug':'demo','baseSha':base,'currentPhase':'deliver',
             'artifacts':{'spec':'docs/loop-spec/features/demo/SPEC.md'},
             'artifactPublication':{'version':1,'generation':0,'evidenceEpoch':0,
                                    'migration':None,'participantsVersion':1}}
    (feature/'feature.json').write_text(json.dumps(state))
    sink = Path(temporary)/'external'
    sink.mkdir()
    with locked_feature(feature):
        token = capture_locked(feature)
    def competing_write(point):
        if point == 'prepared':
            write_operation(feature,'set',['new warning'],keys=('warnings',))
    before_index = (root/'.git/index').read_bytes()
    with check.assertRaisesRegex(ValueError, 'stale'):
        artifact_sink.store(feature,root,sink,token=token,failure=competing_write)
    assert (docs/'SPEC.md').read_text() == 'new requirement'
    assert (docs/'kept.md').read_text() == 'candidate'
    assert (root/'.git/index').read_bytes() == before_index
    assert not list(sink.rglob('manifest.json'))
    with locked_feature(feature):
        token = capture_locked(feature)
    def stop_after_state(point):
        if point == 'state':
            raise OSError('interrupted sink')
    with check.assertRaisesRegex(OSError, 'interrupted sink'):
        artifact_sink.store(feature,root,sink,token=token,failure=stop_after_state)
    artifact_sink.recover(feature,root,sink)
    assert (docs/'SPEC.md').read_text() == 'new requirement'
    assert (docs/'kept.md').read_text() == 'candidate'
    assert (root/'.git/index').read_bytes() == before_index
    assert 'artifactSink' not in json.loads((feature/'feature.json').read_text())
    destination, refreshed = artifact_sink.store(feature,root,sink)
    assert (docs/'kept.md').read_text() == 'baseline'
    assert not (docs/'SPEC.md').exists()
    assert (destination/'artifacts/SPEC.md').read_text() == 'new requirement'
    assert (destination/'artifacts/kept.md').read_text() == 'candidate'
    assert git('show',':docs/loop-spec/features/demo/kept.md') == 'baseline'
    assert refreshed['generation'] > token['generation']
print('PASS: real sink preserves docs/index on stale work and recovers interrupted external publication')
PY

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
