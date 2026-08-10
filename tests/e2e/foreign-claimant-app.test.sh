#!/usr/bin/env bash
# Hermetic offline e2e: a real out-of-process claimant.py claims a bundle put
# on the handoff port, does the work, verifies it, and completes it -- and
# the app.py it produced is started for real and GET / is checked over
# 127.0.0.1. This is the production-consumer proof lib/graph/port.sh and
# lib/graph/handoff.sh otherwise have zero non-test callers for
# (examples/foreign-claimant/README.md).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EXAMPLE="$ROOT/examples/foreign-claimant"
WORK="${TMPDIR:-/tmp}/loop-spec-foreign-claimant-app-e2e.$$"
SERVER_PID=""

cleanup() {
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$WORK/store" "$WORK/target"
PASS=0; FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"; FAIL=$((FAIL + 1))
  fi
}

# 1. Throwaway git repo + feature dir standing in for a real target project.
mkdir -p "$WORK/repo/.loop-spec/features/hello-world"
(
  cd "$WORK/repo"
  git init -q
  git config user.email test@example.com
  git config user.name test
  jq -n '{slug:"hello-world",schemaVersion:7,baseSha:"deadbeef",currentPhase:"execute",branch:"feat/hello-world"}' \
    > .loop-spec/features/hello-world/feature.json
  git add -A
  git commit -q -m init
)
FDIR="$WORK/repo/.loop-spec/features/hello-world"

export LOOP_SPEC_PORT_ROOT="$WORK/store"

# 2. Export + put the real task's bundle. brief/files are what let a claimant
# sharing zero session state with this test act at all -- see the contract
# fix in lib/graph/handoff.sh.
APP_TARGET="$WORK/target/app.py"
VERIFY_CMD="python3 $EXAMPLE/verify.py $APP_TARGET"
bash "$ROOT/lib/graph/handoff.sh" export \
  --feature-dir "$FDIR" --node execute.worker --task task-hello \
  --verify "$VERIFY_CMD" \
  --brief "Serve GET / -> hello world (stdlib http.server)" \
  --files "$(jq -cn --arg p "$APP_TARGET" '[$p]')" \
  --graph "$ROOT/graph/cycle.graph.json" \
  --out "$WORK/bundle-hello.json"
check "export wrote bundle" "0" "$([[ -f "$WORK/bundle-hello.json" ]] && echo 0 || echo 1)"
check "bundle carries brief" "1" "$(jq -e '.brief != null' "$WORK/bundle-hello.json" >/dev/null 2>&1 && echo 1 || echo 0)"
check "bundle carries files" "$APP_TARGET" "$(jq -r '.files[0]' "$WORK/bundle-hello.json")"

id="$(bash "$ROOT/lib/graph/port.sh" put "$WORK/bundle-hello.json" | sed -n 's/^id=//p')"
check "put id non-empty" "1" "$([[ -n "$id" ]] && echo 1 || echo 0)"

listed="$(bash "$ROOT/lib/graph/port.sh" list --claimable)"
check "bundle claimable before anyone claims it" "1" "$(grep -qxF "$id" <<<"$listed" && echo 1 || echo 0)"

# 3. Run claimant.py as a SEPARATE PROCESS with a scrubbed environment: no
# shared shell/session state, only what env -i lets through explicitly (the
# port storage location and the repo root, both operational config -- not
# task content, which comes entirely from the bundle).
rc=0
env -i PATH="$PATH" HOME="${HOME:-/root}" LOOP_SPEC_PORT_ROOT="$WORK/store" \
  python3 "$EXAMPLE/claimant.py" --repo-root "$ROOT" --feature-dir "$FDIR" \
  --owner foreign-agent-1 --ttl 120 \
  > "$WORK/claimant.out" 2> "$WORK/claimant.err" || rc=$?
cat "$WORK/claimant.out" "$WORK/claimant.err"
check "claimant.py exits 0" "0" "$rc"

# 4. claimable -> claimed -> completed, traced through the claimant's own
# transcript (list --claimable is not a reliable "is it done" signal on the
# reference adapter -- complete() clears the claim, so a completed id
# reappears in --claimable; result.json is the actual completion record,
# per skills/execute/SKILL.md's "Collecting a result on re-entry" note).
check "claimant reports it claimed the bundle" "1" \
  "$(grep -q "claimant: claimed $id" "$WORK/claimant.out" && echo 1 || echo 0)"
check "claimant reports completion" "1" \
  "$(grep -q "completed=$id" "$WORK/claimant.out" && echo 1 || echo 0)"
check "result recorded on the port" "0" "$([[ -f "$WORK/store/instances/$id/result.json" ]] && echo 0 || echo 1)"
check "claim released after complete" "1" "$([[ ! -f "$WORK/store/instances/$id/claim.json" ]] && echo 1 || echo 0)"
check "app.py written to the target path" "0" "$([[ -f "$APP_TARGET" ]] && echo 0 || echo 1)"

# 5. Start the produced app.py for real and GET / over 127.0.0.1.
python3 "$APP_TARGET" --port 0 > "$WORK/server.out" 2>"$WORK/server.err" &
SERVER_PID=$!
port=""
for _ in $(seq 1 50); do
  port="$(head -n1 "$WORK/server.out" 2>/dev/null || true)"
  if [[ -n "$port" ]]; then
    break
  fi
  sleep 0.1
done
check "server printed a bound port" "1" "$([[ "$port" =~ ^[0-9]+$ ]] && echo 1 || echo 0)"
status="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/")"
body="$(curl -s "http://127.0.0.1:$port/")"
echo "GET http://127.0.0.1:$port/ -> status=$status body=$body"
check "GET / status" "200" "$status"
check "GET / body" "hello world" "$body"
kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""

# 6. A second claimant cannot claim the same work while a lease holds. Fresh
# dedicated bundle: claimant.py's own claim+complete happens too fast in one
# process to leave an observable claimed-but-not-completed window, so this
# exercises the same port.sh guarantee claimant.py step 2 relies on directly.
bash "$ROOT/lib/graph/handoff.sh" export \
  --feature-dir "$FDIR" --node execute.worker --task task-lease \
  --verify true --graph "$ROOT/graph/cycle.graph.json" \
  --out "$WORK/bundle-lease.json"
id_lease="$(bash "$ROOT/lib/graph/port.sh" put "$WORK/bundle-lease.json" | sed -n 's/^id=//p')"
bash "$ROOT/lib/graph/port.sh" claim "$id_lease" holder 60 >/dev/null
rc=0
bash "$ROOT/lib/graph/port.sh" claim "$id_lease" intruder 60 >/dev/null 2>&1 || rc=$?
check "second claimant refused while lease holds" "1" "$rc"

# 7a. A claimant that forges its result hash instead of doing honest work is
# rejected by complete: `complete` never reads result-json for the hash, it
# re-derives one from the live feature-dir (skills/shared/handoff-port.md).
bash "$ROOT/lib/graph/handoff.sh" export \
  --feature-dir "$FDIR" --node execute.worker --task task-forge \
  --verify true --graph "$ROOT/graph/cycle.graph.json" \
  --out "$WORK/bundle-forge.json"
id_forge="$(bash "$ROOT/lib/graph/port.sh" put "$WORK/bundle-forge.json" | sed -n 's/^id=//p')"
bash "$ROOT/lib/graph/port.sh" claim "$id_forge" dishonest 60 >/dev/null
mkdir -p "$WORK/rigged-feat"
jq '.currentPhase = "rigged"' "$FDIR/feature.json" > "$WORK/rigged-feat/feature.json"
jq -n '{stateHash:"forged-by-claimant",ok:true}' > "$WORK/forged-result.json"
rc=0
bash "$ROOT/lib/graph/port.sh" complete "$id_forge" "$WORK/forged-result.json" "$WORK/rigged-feat" \
  >/dev/null 2>&1 || rc=$?
check "forged-hash complete rejected" "1" "$rc"
check "forged-hash left unmerged" "1" "$([[ ! -f "$WORK/store/instances/$id_forge/result.json" ]] && echo 1 || echo 0)"

# 7b. A claimant that does NOT do the work fails its own verify gate and
# must never reach a successful complete (claimant.py's refuse-if-verify-
# fails step). This is exactly what the mutation proof (see suite comment
# in tests/run-all.sh registration / README) exercises against the real
# claimant.py: skip the work, skip this gate, and the suite fails downstream
# at step 5 because there is nothing at the target path to serve.
LAZY_TARGET="$WORK/target-lazy/app.py"
bash "$ROOT/lib/graph/handoff.sh" export \
  --feature-dir "$FDIR" --node execute.worker --task task-lazy \
  --verify "python3 $EXAMPLE/verify.py $LAZY_TARGET" \
  --files "$(jq -cn --arg p "$LAZY_TARGET" '[$p]')" \
  --graph "$ROOT/graph/cycle.graph.json" \
  --out "$WORK/bundle-lazy.json"
id_lazy="$(bash "$ROOT/lib/graph/port.sh" put "$WORK/bundle-lazy.json" | sed -n 's/^id=//p')"
bash "$ROOT/lib/graph/port.sh" claim "$id_lazy" lazy-agent 60 >/dev/null
rc=0
python3 "$EXAMPLE/verify.py" "$LAZY_TARGET" >/dev/null 2>&1 || rc=$?
check "verify fails when the work was skipped" "1" "$rc"
bash "$ROOT/lib/graph/port.sh" release "$id_lazy" >/dev/null
check "skipped-work claim never completed" "1" "$([[ ! -f "$WORK/store/instances/$id_lazy/result.json" ]] && echo 1 || echo 0)"

# --- 6. The claimant's OWN verify gate blocks completion -------------------
# The case above proves verify.py fails on missing work; it does not exercise
# claimant.py's refusal path, because it never runs claimant.py. Mutating
# `if verify.returncode != 0:` to `if False:` therefore survived the suite.
# Here the work IS done but the bundle's verifyCommand always fails, so the
# only thing that can stop a complete is the claimant's own gate.
FAILV_TARGET="$WORK/target-failv/app.py"
bash "$ROOT/lib/graph/handoff.sh" export \
  --feature-dir "$FDIR" --node execute.worker --task task-failv \
  --verify "false" \
  --files "$(jq -cn --arg p "$FAILV_TARGET" '[$p]')" \
  --graph "$ROOT/graph/cycle.graph.json" \
  --out "$WORK/bundle-failv.json"
# A DEDICATED store: the claimant takes whichever bundle is claimable first,
# and earlier sections leave instances behind in the shared one, so this case
# would otherwise assert against a bundle it never claimed.
FAILV_STORE="$WORK/store-failv"
id_failv="$(LOOP_SPEC_PORT_ROOT="$FAILV_STORE" bash "$ROOT/lib/graph/port.sh" put "$WORK/bundle-failv.json" | sed -n 's/^id=//p')"

rc=0
env -i PATH="$PATH" HOME="$HOME" LOOP_SPEC_PORT_ROOT="$FAILV_STORE" \
  python3 "$EXAMPLE/claimant.py" \
  --repo-root "$ROOT" --feature-dir "$FDIR" --owner failv-agent >/dev/null 2>&1 || rc=$?
check "claimant exits non-zero when its verify command fails" "1" "$rc"
check "claimant did NOT complete work whose verify failed" "1" \
  "$([[ ! -f "$FAILV_STORE/instances/$id_failv/result.json" ]] && echo 1 || echo 0)"
check "claimant released the lease it could not complete" "1" \
  "$(LOOP_SPEC_PORT_ROOT="$FAILV_STORE" bash "$ROOT/lib/graph/port.sh" list --claimable | grep -qF "$id_failv" && echo 1 || echo 0)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
