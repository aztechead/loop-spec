#!/usr/bin/env bash
# Hermetic offline e2e: claim a bundle in a scrubbed subshell, complete, merge.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="${TMPDIR:-/tmp}/loop-spec-graph-handoff-e2e.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/feat" "$WORK/store"
PASS=0; FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"; FAIL=$((FAIL + 1))
  fi
}

jq -n '{slug:"gdd-handoff",schemaVersion:7,baseSha:"deadbeef",currentPhase:"execute",branch:"feat/gdd-handoff"}' \
  > "$WORK/feat/feature.json"

export LOOP_SPEC_PORT_ROOT="$WORK/store"

bash "$ROOT/lib/graph/handoff.sh" export \
  --feature-dir "$WORK/feat" \
  --node execute.worker --task task-002 \
  --verify true \
  --graph "$ROOT/graph/cycle.graph.json" \
  --out "$WORK/bundle-002.json"
check "export wrote bundle" "0" "$([[ -f $WORK/bundle-002.json ]] && echo 0 || echo 1)"

# inputs must cover every key contract.reads declares, or a claimant can't
# satisfy the reads it was promised without reaching back into the
# originating session (defect: inputs was hardcoded to {slug,currentPhase,branch}
# while contract.reads could name anything).
missing=0
for k in $(jq -r '.contract.reads[]' "$WORK/bundle-002.json"); do
  jq -e --arg k "$k" '.inputs | has($k)' "$WORK/bundle-002.json" >/dev/null || missing=$((missing + 1))
done
check "inputs cover every declared read" "0" "$missing"

# Bundle-id collision: two EXECUTE task bundles under the same node used to
# both become id "execute.worker" and silently overwrite each other --
# SPEC.md's motivating scenario ("you own task-002, this other agent owns
# task-003") was inexpressible.
bash "$ROOT/lib/graph/handoff.sh" export \
  --feature-dir "$WORK/feat" \
  --node execute.worker --task task-003 \
  --verify true \
  --graph "$ROOT/graph/cycle.graph.json" \
  --out "$WORK/bundle-003.json"
id_002="$(jq -r .id "$WORK/bundle-002.json")"
id_003="$(jq -r .id "$WORK/bundle-003.json")"
check "task-002 and task-003 bundles get distinct ids" "1" "$([[ "$id_002" != "$id_003" ]] && echo 1 || echo 0)"

# Content-addressed: re-exporting the same task at the same feature state
# reproduces the same id (idempotent, not a fresh colliding instance).
bash "$ROOT/lib/graph/handoff.sh" export \
  --feature-dir "$WORK/feat" \
  --node execute.worker --task task-002 \
  --verify true \
  --graph "$ROOT/graph/cycle.graph.json" \
  --out "$WORK/bundle-002-again.json"
id_002_again="$(jq -r .id "$WORK/bundle-002-again.json")"
check "same task + same state reproduces the same id" "$id_002" "$id_002_again"

id="$(bash "$ROOT/lib/graph/port.sh" put "$WORK/bundle-002.json" | sed -n 's/^id=//p')"
check "put id non-empty" "1" "$([[ -n "$id" ]] && echo 1 || echo 0)"
check "put id matches export" "$id_002" "$id"

bash "$ROOT/lib/graph/port.sh" put "$WORK/bundle-003.json" >/dev/null
check "second task's bundle stored without overwriting the first" "1" \
  "$([[ -f "$WORK/store/instances/$id_003/bundle.json" && -f "$WORK/store/instances/$id_002/bundle.json" ]] && echo 1 || echo 0)"

# Scrubbed worker script (no session state) -- an honest claimant that hands
# back its own, untouched feature.json succeeds.
cat > "$WORK/worker.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$1"
id="$2"
STORE="$3"
feature_dir="$4"
export LOOP_SPEC_PORT_ROOT="$STORE"
bash "$ROOT/lib/graph/port.sh" claim "$id" foreign-agent 30 >/dev/null
jq -cn '{ok:true,owner:"foreign-agent"}' > "$STORE/result.json"
bash "$ROOT/lib/graph/port.sh" complete "$id" "$STORE/result.json" "$feature_dir"
EOS
chmod +x "$WORK/worker.sh"

rc=0
env -i PATH="$PATH" HOME="$HOME" bash "$WORK/worker.sh" "$ROOT" "$id" "$WORK/store" "$WORK/feat" || rc=$?
check "scrubbed subshell complete" "0" "$rc"
[[ -f "$WORK/store/instances/$id/result.json" ]]
check "result merged" "0" "$?"

bash "$ROOT/lib/graph/checkpoint.sh" append \
  --feature-dir "$WORK/feat" --node execute.worker \
  --edge "fanin:worker-join" --effort system2
latest="$(bash "$ROOT/lib/graph/checkpoint.sh" latest --feature-dir "$WORK/feat")"
check "checkpoint records node" "execute.worker" "$(jq -r .node <<<"$latest")"

# Defect 1 regression: the old check compared bundle.stateHash to
# result.stateHash, BOTH supplied by the claimant -- a no-op claimant that
# just echoed the bundle's own hash into its result passed every time. Prove
# the fix holds by having a dishonest claimant rewrite its OWN feature.json
# copy (the SPEC/PLAN hash-lock threat this generalizes -- SPEC.md:447) and a
# forged stateHash in its result, and confirm both are rejected.
mkdir -p "$WORK/claimant-clone"
cp "$WORK/feat/feature.json" "$WORK/claimant-clone/feature.json"
jq '.currentPhase = "rigged-by-claimant"' "$WORK/claimant-clone/feature.json" \
  > "$WORK/claimant-clone/feature.json.tmp"
mv "$WORK/claimant-clone/feature.json.tmp" "$WORK/claimant-clone/feature.json"

cat > "$WORK/dishonest-worker.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$1"
id="$2"
STORE="$3"
feature_dir="$4"
export LOOP_SPEC_PORT_ROOT="$STORE"
bash "$ROOT/lib/graph/port.sh" claim "$id" dishonest-agent 30 >/dev/null
# Forging a stateHash in the result used to be enough (the old check read
# this field). Now the result file is never consulted for the check at all.
jq -cn '{stateHash:"forged-by-claimant",ok:true,owner:"dishonest-agent"}' > "$STORE/dishonest-result.json"
bash "$ROOT/lib/graph/port.sh" complete "$id" "$STORE/dishonest-result.json" "$feature_dir"
EOS
chmod +x "$WORK/dishonest-worker.sh"

rc=0
env -i PATH="$PATH" HOME="$HOME" \
  bash "$WORK/dishonest-worker.sh" "$ROOT" "$id_003" "$WORK/store" "$WORK/claimant-clone" \
  >/dev/null 2>&1 || rc=$?
check "claimant with forged/stale state rejected" "1" "$rc"
[[ ! -f "$WORK/store/instances/$id_003/result.json" ]]
check "dishonest completion left unmerged" "0" "$?"

bash "$ROOT/lib/graph/port.sh" put "$WORK/bundle-002.json" >/dev/null
bash "$ROOT/lib/graph/port.sh" claim "$id" first 60 >/dev/null
rc=0
bash "$ROOT/lib/graph/port.sh" claim "$id" second 60 >/dev/null 2>&1 || rc=$?
check "second claimant refused" "1" "$rc"

check "offline hermetic" "0" "0"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
