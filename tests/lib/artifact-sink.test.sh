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

# A stale index.lock (the Git process that made it died mid-write) must make
# recover refuse cleanly, without deleting a lock it does not own. The index is
# binary (embedded NULs), so compare it with cmp rather than through $(...).
lock_before="$WORK-index-before"
cp "$WORK/.git/index" "$lock_before"
touch "$WORK/.git/index.lock"
rc=0
lock_out="$(bash "$LIB" recover "$feature" "$WORK" 2>&1)" || rc=$?
check "stale index.lock: recover exits 1" "1" "$rc"
check "stale index.lock: message names it" "1" \
  "$(grep -c 'Git index is locked' <<<"$lock_out")"
check "stale index.lock: recover does not delete a lock it does not own" "1" \
  "$([[ -f "$WORK/.git/index.lock" ]] && echo 1 || echo 0)"
check "stale index.lock: index bytes unchanged" "1" \
  "$(cmp -s "$WORK/.git/index" "$lock_before" && echo 1 || echo 0)"
rm -f "$WORK/.git/index.lock" "$lock_before"

PYTHONPATH="$ROOT/lib" python3 - <<'PY'
import json, os, subprocess, tempfile
from pathlib import Path
from unittest import TestCase
import artifact_sink
from artifact_publication import capture_locked, locked_feature
from feature_write import write_operation

check = TestCase()

def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args]).decode().strip()

def default_baseline(docs):
    (docs / 'kept.md').write_text('baseline')

def default_candidate(docs):
    (docs / 'kept.md').write_text('candidate')
    (docs / 'SPEC.md').write_text('new requirement')

def build_fixture(base_dir, baseline=default_baseline, candidate=default_candidate):
    """A minimal store()-ready repo: a baseline commit, then a candidate commit
    (by default, one that adds SPEC.md over an unrelated kept.md -- pass
    `baseline`/`candidate` to shape the docs tree differently, e.g. to commit an
    executable document). Returns (root, feature, sink, token) with token
    captured before any store() call, mirroring what a real caller holds at
    ingress."""
    root = base_dir / 'repo'
    root.mkdir()
    git(root, 'init', '-q', '-b', 'main')
    git(root, 'config', 'user.name', 'Test')
    git(root, 'config', 'user.email', 'test@example.com')
    docs = root / 'docs/loop-spec/features/demo'
    docs.mkdir(parents=True)
    baseline(docs)
    git(root, 'add', '.')
    git(root, 'commit', '-qm', 'baseline')
    base = git(root, 'rev-parse', 'HEAD')
    candidate(docs)
    git(root, 'add', '-A', '.')
    git(root, 'commit', '-qm', 'candidate')
    feature = root / '.loop-spec/features/demo'
    feature.mkdir(parents=True)
    state = {'schemaVersion': 7, 'slug': 'demo', 'baseSha': base, 'currentPhase': 'deliver',
             'artifacts': {'spec': 'docs/loop-spec/features/demo/SPEC.md'},
             'artifactPublication': {'version': 1, 'generation': 0, 'evidenceEpoch': 0,
                                      'migration': None, 'participantsVersion': 1}}
    (feature / 'feature.json').write_text(json.dumps(state))
    sink = base_dir / 'external'
    sink.mkdir()
    with locked_feature(feature):
        token = capture_locked(feature)
    return root, feature, sink, token

# A competing write during preparation and a crash after the transaction's own
# state write both leave docs/index untouched or recoverable, and generation
# advances only on the accepted attempt.
with tempfile.TemporaryDirectory() as temporary:
    root, feature, sink, token = build_fixture(Path(temporary))
    docs = root / 'docs/loop-spec/features/demo'
    def competing_write(point):
        if point == 'prepared':
            write_operation(feature, 'set', ['new warning'], keys=('warnings',))
    before_index = (root / '.git/index').read_bytes()
    with check.assertRaisesRegex(ValueError, 'stale'):
        artifact_sink.store(feature, root, sink, token=token, failure=competing_write)
    assert (docs / 'SPEC.md').read_text() == 'new requirement'
    assert (docs / 'kept.md').read_text() == 'candidate'
    assert (root / '.git/index').read_bytes() == before_index
    assert not list(sink.rglob('manifest.json'))
    with locked_feature(feature):
        token = capture_locked(feature)
    def stop_after_state(point):
        if point == 'state':
            raise OSError('interrupted sink')
    with check.assertRaisesRegex(OSError, 'interrupted sink'):
        artifact_sink.store(feature, root, sink, token=token, failure=stop_after_state)
    artifact_sink.recover(feature, root, sink)
    assert (docs / 'SPEC.md').read_text() == 'new requirement'
    assert (docs / 'kept.md').read_text() == 'candidate'
    assert (root / '.git/index').read_bytes() == before_index
    assert 'artifactSink' not in json.loads((feature / 'feature.json').read_text())
    destination, refreshed = artifact_sink.store(feature, root, sink)
    assert (docs / 'kept.md').read_text() == 'baseline'
    assert not (docs / 'SPEC.md').exists()
    assert (destination / 'artifacts/SPEC.md').read_text() == 'new requirement'
    assert (destination / 'artifacts/kept.md').read_text() == 'candidate'
    assert git(root, 'show', ':docs/loop-spec/features/demo/kept.md') == 'baseline'
    assert refreshed['generation'] > token['generation']
print('PASS: real sink preserves docs/index on stale work and recovers interrupted external publication')

# (a) A baseline document's ls-tree executable bit survives being restored --
# whether the candidate had dropped it (mode differs from an existing target)
# or removed the document outright (no existing target for publish_locked to
# inherit a mode from at all) -- and survives an interrupted-then-recovered
# attempt without publish_locked (out of this module's scope) ever needing a
# mode concept.
def executable_baseline(docs):
    (docs / 'changed-mode.sh').write_text('#!/bin/sh\necho baseline\n')
    os.chmod(docs / 'changed-mode.sh', 0o755)
    (docs / 'deleted.sh').write_text('#!/bin/sh\necho baseline\n')
    os.chmod(docs / 'deleted.sh', 0o755)

def executable_candidate(docs):
    os.chmod(docs / 'changed-mode.sh', 0o644)  # candidate dropped +x
    (docs / 'deleted.sh').unlink()             # candidate deleted it outright

with tempfile.TemporaryDirectory() as temporary:
    root, feature, sink, token = build_fixture(Path(temporary), executable_baseline, executable_candidate)
    docs = root / 'docs/loop-spec/features/demo'
    def stop_after_state(point):
        if point == 'state':
            raise OSError('interrupted sink (mode fixture)')
    with check.assertRaisesRegex(OSError, 'interrupted sink'):
        artifact_sink.store(feature, root, sink, token=token, failure=stop_after_state)
    artifact_sink.recover(feature, root, sink)
    assert os.stat(docs / 'changed-mode.sh').st_mode & 0o777 == 0o644, \
        "recover must restore the candidate's own mode, not baseline's"

    destination, refreshed = artifact_sink.store(feature, root, sink)
    assert os.stat(docs / 'changed-mode.sh').st_mode & 0o777 == 0o755, \
        "a baseline document whose candidate mode had drifted must come back executable"
    assert os.stat(docs / 'deleted.sh').st_mode & 0o777 == 0o755, \
        "a baseline document deleted from the candidate must come back executable, not the tempfile default"
print('PASS: a baseline document keeps its ls-tree executable bit through store and through an interrupted recovery')

# (c) The archived state/feature.json is the pre-publication snapshot: its own
# generation matches the ingress generation, one behind the live feature.json.
with tempfile.TemporaryDirectory() as temporary:
    root, feature, sink, token = build_fixture(Path(temporary))
    ingress_generation = token['generation']
    destination, refreshed = artifact_sink.store(feature, root, sink)
    manifest = json.loads((destination / 'manifest.json').read_text())
    archived_state = json.loads((destination / 'state/feature.json').read_text())
    live_state = json.loads((feature / 'feature.json').read_text())
    assert manifest['stateCapturedAtGeneration'] == ingress_generation
    assert archived_state['artifactPublication']['generation'] == ingress_generation
    assert live_state['artifactPublication']['generation'] == ingress_generation + 1
    assert live_state['artifactSink']['mode'] == 'store'
print('PASS: the archived state is the pre-publication snapshot; the live feature.json is one generation ahead with artifactSink set')

# (d) A document added between capture and acceptance (the "prepared" failure
# hook fires right after staging, before the final re-check) makes store fail
# as stale and leaves docs and the index untouched.
with tempfile.TemporaryDirectory() as temporary:
    root, feature, sink, token = build_fixture(Path(temporary))
    docs = root / 'docs/loop-spec/features/demo'
    doc_files_before = sorted(str(p.relative_to(docs)) for p in docs.rglob('*') if p.is_file())
    before_index = (root / '.git/index').read_bytes()
    def add_a_file(point):
        if point == 'prepared':
            (docs / 'surprise.md').write_text('added mid-transaction')
    with check.assertRaisesRegex(ValueError, 'stale artifact sink source files'):
        artifact_sink.store(feature, root, sink, token=token, failure=add_a_file)
    doc_files_after = sorted(str(p.relative_to(docs)) for p in docs.rglob('*') if p.is_file())
    assert doc_files_after == doc_files_before + ['surprise.md'], \
        "the failure hook's own write is the only change -- store must not have touched anything else"
    assert (root / '.git/index').read_bytes() == before_index
    assert not list(sink.rglob('manifest.json'))
print('PASS: a document added during preparation is rechecked and fails store as stale, changing nothing else')

# (e) A second store() after an accepted one, holding the token captured
# before the FIRST store, fails as stale and changes nothing.
with tempfile.TemporaryDirectory() as temporary:
    root, feature, sink, old_token = build_fixture(Path(temporary))
    docs = root / 'docs/loop-spec/features/demo'
    destination, refreshed = artifact_sink.store(feature, root, sink)
    before_index = (root / '.git/index').read_bytes()
    before_spec_exists = (docs / 'SPEC.md').exists()
    with check.assertRaisesRegex(ValueError, 'stale'):
        artifact_sink.store(feature, root, sink, token=old_token)
    assert (root / '.git/index').read_bytes() == before_index
    assert (docs / 'SPEC.md').exists() == before_spec_exists
print('PASS: a retry with the token captured before an already-accepted store fails as stale and changes nothing')

# (f) An unrelated state write between capture and store makes the held token
# stale before store ever touches SPEC.md or the index.
with tempfile.TemporaryDirectory() as temporary:
    root, feature, sink, token = build_fixture(Path(temporary))
    docs = root / 'docs/loop-spec/features/demo'
    write_operation(feature, 'set', ['unrelated'], keys=('warnings',))
    before_index = (root / '.git/index').read_bytes()
    before_spec = (docs / 'SPEC.md').read_text()
    with check.assertRaisesRegex(ValueError, 'stale'):
        artifact_sink.store(feature, root, sink, token=token)
    assert (docs / 'SPEC.md').read_text() == before_spec
    assert (root / '.git/index').read_bytes() == before_index
print('PASS: a stale token from an unrelated state write cannot overwrite current artifacts')
PY

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
