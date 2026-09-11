#!/usr/bin/env bash
# Executable publication participants retain the token that admitted their work.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0; FAIL=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"; FAIL=$((FAIL + 1))
  fi
}

# --- completeness: every file that touches the publication contract is accounted for --
# Swept from the TREE at call time (never a stored list), exactly as CLAUDE.md's
# lib/surface.sh does it: a file this misses is a caller nobody proved carries its
# token, and an allow-list entry with no matching file is dead weight the next reader
# would trust by mistake. The second grep is feature.json's OTHER publishers -- direct
# readers/writers that never mention feature-write.sh by name -- filtered to lines
# that actually write (a read-only mention, or a comment naming the convention, is not
# a caller). Manual audit of every hit below (2026-09-10, task-004 WP2) found none
# outside the first grep's set; the filter still runs so a NEW one fails loudly instead
# of silently passing as "already covered".
ALLOWLIST_HANDLED="
lib/artifact_sink.py
lib/checkpoint-pr.sh
lib/deliver.sh
lib/execute-prepare.sh
lib/execute-step.sh
lib/execute_remediation.py
lib/feature-bootstrap.sh
lib/feature-init.sh
lib/feature_write.py
lib/graph/driver.py
lib/graph/engine.py
lib/graph/gate.sh
lib/graph/state.sh
lib/iterate-judged.sh
lib/phase-exit.sh
lib/revise-state.sh
lib/verify-gate.sh
lib/verify-prepare.sh
"
# Read-only users (never call a write path) and mentions that are prose, not code --
# a comment describing the convention, a hook's denial message naming the one writer
# that MAY touch a contract file, or a test asserting that message.
ALLOWLIST_OTHER="
hooks/restrict-agent-paths.sh
hooks/team/result-forgery-guard.sh
hooks/team/result-forgery-guard.test.sh
lib/cycle-result.sh
lib/execution_observation.py
lib/greenfield-bootstrap.sh
lib/harness.sh
lib/phase-entry.sh
lib/quality-loop-state.sh
"
# Infrastructure: the contract's own implementation, not a caller of it. Exercised
# directly by this suite and by tests/lib/artifact-publication*.test.sh, never by
# scanning its own source for a mention of itself.
ALLOWLIST_INFRA="
lib/artifact_publication.py
lib/feature-write.sh
lib/publication_participant.py
"
allowed="$(printf '%s\n%s\n%s\n' "$ALLOWLIST_HANDLED" "$ALLOWLIST_OTHER" "$ALLOWLIST_INFRA" | sed '/^$/d' | sort -u)"

combined="$( { grep -rln 'feature-write\.sh\|feature_write\|loop_spec_feature_write\|loop_spec_publication_begin' \
                 "$ROOT/lib" "$ROOT/hooks" "$ROOT/extensions" --include='*.sh' --include='*.py' --include='*.ts' 2>/dev/null
               files="$(grep -rl 'feature\.json' "$ROOT/lib" --include='*.sh' --include='*.py' 2>/dev/null)"
               [[ -z "$files" ]] || grep -lE 'feature-write\.sh|loop_spec_feature_write|loop_spec_publication_begin|write_operation|write_state_locked|fset\(' $files 2>/dev/null
             } | sed "s#^$ROOT/##" | sort -u)"

unlisted=0
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  grep -qxF "$f" <<<"$allowed" || { echo "  unlisted publication participant: $f"; unlisted=$((unlisted + 1)); }
done <<<"$combined"
check "every file touching the publication contract is on this suite's allow-list" "0" "$unlisted"

# An allow-list entry for a file that no longer exists (renamed, deleted) is a stale
# claim of coverage; catch that the same way graphify's removal is cited everywhere
# else in this codebase -- a map that can go wrong silently is worse than none.
stale=0
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  [[ -f "$ROOT/$f" ]] || { echo "  allow-listed file no longer exists: $f"; stale=$((stale + 1)); }
done <<<"$allowed"
check "no allow-list entry names a file that no longer exists" "0" "$stale"

PYTEST_RC=0
PYTHONPATH="$ROOT/lib" python3 - "$ROOT" <<'PYTEST' || PYTEST_RC=$?
import json, tempfile, sys, subprocess, os
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / "lib/graph"))
from artifact_publication import capture_locked, locked_feature
import feature_write

with tempfile.TemporaryDirectory() as work:
    directory = Path(work) / "resumed/.loop-spec/features/fixture"
    directory.mkdir(parents=True)
    state = {"slug":"fixture", "warnings":[], "artifacts":{"tasks":"/old/.loop-spec/features/fixture/tasks.json"},
             "artifactPublication":{"version":1,"generation":0,"evidenceEpoch":0,"migration":None,"participantsVersion":1}}
    (directory / "feature.json").write_text(json.dumps(state))
    (directory / "tasks.json").write_text("[]")
    registry = {"tasks":"tasks.json"}
    with locked_feature(directory):
        token = capture_locked(directory, registry)
    refreshed = feature_write.write_operation(directory, "set", ["accepted"], ["warnings"], token=token, registry=registry)
    assert refreshed["generation"] == 1
    accepted = (directory / "feature.json").read_bytes()
    try:
        feature_write.write_operation(directory, "set", ["stale"], ["warnings"], token=token, registry=registry)
    except ValueError as exc:
        assert "stale publication token" in str(exc)
    else:
        raise AssertionError("stale relocated writer succeeded")
    assert (directory / "feature.json").read_bytes() == accepted
    assert refreshed["inputs"]["tasks"]["path"] == str(directory / "tasks.json")
    for operation, value, keys in (("set", {}, ["currentGate"]), ("set", [], ["gateHistory"])):
        try:
            feature_write.write_operation(directory, operation, value, keys, token=refreshed, registry=registry)
        except ValueError as exc:
            assert "written only by lib/graph/gate.sh" in str(exc)
        else:
            raise AssertionError("trusted seam bypassed the gate controller")
        assert (directory / "feature.json").read_bytes() == accepted
    print("PASS: trusted writer preserves gate-controller authorization")
    print("PASS: relocated writer retains original token and returns only its own accepted refresh")
    import execute_remediation
    state["artifacts"] = {"tasks":str(directory / "tasks.json")}
    state["commands"] = {"test":"true"}
    state["pendingRemediationTasks"] = [{"id":"repair", "subject":"repair finding"}]
    (directory / "feature.json").write_text(json.dumps(state))
    with locked_feature(directory):
        token = capture_locked(directory)
    assert execute_remediation.register(directory, directory / "tasks.json", token=token) == 1
    accepted = [(directory / name).read_bytes() for name in ("feature.json", "tasks.json")]
    try:
        execute_remediation.register(directory, directory / "tasks.json", token=token)
    except ValueError as exc:
        assert "stale publication token" in str(exc)
    else:
        raise AssertionError("stale remediation acknowledgment succeeded")
    assert accepted == [(directory / name).read_bytes() for name in ("feature.json", "tasks.json")]
    assert json.loads(accepted[0])["pendingRemediationTasks"] == []
    state["pendingRemediationTasks"] = [{"id":"repair-after-migration", "subject":"repair finding"}]
    (directory / "feature.json").write_text(json.dumps(state))
    def migrating_reader(path):
        before = json.loads((directory / "feature.json").read_text())
        migrated = json.loads(json.dumps(before))
        migrated["artifactPublication"]["generation"] += 1
        (directory / "feature.json").write_text(json.dumps(migrated))
        return before
    sidecar_before = (directory / "tasks.json").read_bytes()
    try:
        execute_remediation.register(directory, directory / "tasks.json", reader=migrating_reader)
    except ValueError as exc:
        assert "stale publication token" in str(exc)
    else:
        raise AssertionError("remediation read before migration was accepted afterward")
    assert (directory / "tasks.json").read_bytes() == sidecar_before
    assert json.loads((directory / "feature.json").read_text())["pendingRemediationTasks"] == state["pendingRemediationTasks"]
    print("PASS: remediation tasks and queue acknowledgment share original-token publication")
    import driver
    from requirements import initialize_contract, parse_spec, reconcile_inventory
    owner = {"repository":"stable-repo", "feature":"fixture"}
    contract = initialize_contract(owner, "v1")
    spec = directory / "SPEC.md"
    text = "\n".join(["---", "requirements_version: 1", "requirements_owner: " + json.dumps(owner),
                      "scenario_checks: {}", "---", "## Goals", "Preserve  exact intent.", "", "## Boundaries",
                      "Stay within bounds.", "", "### Good Enough", "- [ ] GE-009: Ninth outcome",
                      "  - SC-002: Ninth scenario", "- [ ] GE-003: Third outcome", "  - SC-001: Third scenario", ""])
    spec.write_text(text)
    contract = reconcile_inventory(contract, parse_spec(text, str(spec), contract))
    inputs = {"version":1,"toolchains":[],"localInputs":[],"externalInputs":[],"sensitiveInputs":[]}
    driver.spec_fill(str(spec), {"command":"true", "expect":"Updated ninth outcome", "row":"GE-009",
                               "scenario":"SC-002", "execution_inputs":inputs}, contract=contract)
    result = spec.read_text()
    inventory = parse_spec(result, str(spec), contract)
    assert [r["id"] for r in inventory["requirements"]] == ["GE-009", "GE-003"]
    assert inventory["requirements"][0]["text"] == "Updated ninth outcome"
    assert "- [ ] GE-003: Third outcome\n  - SC-001: Third scenario" in result
    assert text.split("### Good Enough")[0].split("---\n",2)[-1] == result.split("### Good Enough")[0].split("---\n",2)[-1]
    try:
        driver.spec_fill(str(spec), {"command":"true", "expect":"Alias", "row":"1", "execution_inputs":inputs}, contract=contract)
    except driver.Die:
        pass
    else:
        raise AssertionError("v1 writer accepted a numeric positional alias")
    assert spec.read_text() == result
    print("PASS: v1 fill replaces by stable identity after reorder and preserves intent bytes")
    shell_feature = directory.parent / "shell"
    shell_feature.mkdir()
    (shell_feature / "feature.json").write_text(json.dumps({"schemaVersion":7,"slug":"shell","currentPhase":"spec","artifacts":{},"warnings":[]}))
    original_token = feature_write.begin_operation(shell_feature)
    assert original_token["generation"] == 0
    recorded = json.loads((shell_feature / "feature.json").read_text())
    assert recorded["requirementsContract"]["format"] == "legacy"
    incoming, outgoing = shell_feature / "incoming.json", shell_feature / "outgoing.json"
    incoming.write_text(json.dumps(original_token))
    child = shell_feature / "child.sh"
    child.write_text("""source "$1/lib/feature-write.sh"
loop_spec_publication_begin "$2"
loop_spec_feature_write set "$2" warnings '["child"]'
""")
    script = """source "$1/lib/feature-write.sh"
loop_spec_publication_begin "$2"
loop_spec_feature_write set "$2" warnings '["parent"]'
loop_spec_publication_run bash -eu "$2/child.sh" "$1" "$2"
"""

    environment = dict(os.environ, LOOP_SPEC_PUBLICATION_TOKEN=str(incoming), LOOP_SPEC_PUBLICATION_TOKEN_OUTPUT=str(outgoing))
    command = ["bash","-euc",script,"parent",sys.argv[1],str(shell_feature)]
    result = subprocess.run(command, env=environment, text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    assert json.loads(outgoing.read_text())["generation"] == 2
    assert json.loads(incoming.read_text()) == original_token
    accepted = (shell_feature / "feature.json").read_bytes()
    result = subprocess.run(command, env=environment, text=True, capture_output=True)
    assert result.returncode != 0 and "stale publication token" in result.stderr
    assert (shell_feature / "feature.json").read_bytes() == accepted
    print("PASS: shell parent adopts only accepted child refresh and never overwrites original ingress")

    # loop_spec_publication_begin must refuse to alias the immutable input token onto
    # the output slot a caller reads its own refresh from.
    guard_feature = directory.parent / "guard"
    guard_feature.mkdir()
    (guard_feature / "feature.json").write_text(json.dumps({"schemaVersion":7,"slug":"guard","currentPhase":"spec","artifacts":{},"warnings":[]}))
    same_token = guard_feature / "same.json"
    same_token.write_text(json.dumps({"version":1,"generation":0}))
    guard_script = 'source "$1/lib/feature-write.sh"\nloop_spec_publication_begin "$2"\n'
    result = subprocess.run(["bash","-euc",guard_script,"guard",sys.argv[1],str(guard_feature)],
                            env=dict(os.environ, LOOP_SPEC_PUBLICATION_TOKEN=str(same_token),
                                      LOOP_SPEC_PUBLICATION_TOKEN_OUTPUT=str(same_token)),
                            text=True, capture_output=True)
    assert result.returncode != 0, result.stdout
    assert "must not be the input token" in result.stderr, result.stderr
    assert same_token.read_text() == json.dumps({"version":1,"generation":0})
    print("PASS: loop_spec_publication_begin refuses an output slot that names the immutable input token")

    # Token files are small JSON; a bound stops a corrupted or hostile file from being
    # read whole into memory or shell variables.
    read_script = 'source "$1/lib/feature-write.sh"\nLOOP_SPEC_PUBLICATION_WRITER="$1/lib/feature_write.py"\nloop_spec_publication_read "$2"\n'
    big_token = guard_feature / "big.json"
    big_token.write_bytes(b"x" * (1024 * 1024 + 10))
    result = subprocess.run(["bash","-euc",read_script,"bound",sys.argv[1],str(big_token)], text=True, capture_output=True)
    assert result.returncode != 0, result.stdout
    assert "loop_spec_publication_read" in result.stderr, result.stderr
    small_token = guard_feature / "small.json"
    small_token.write_text(json.dumps({"ok":True}))
    result = subprocess.run(["bash","-euc",read_script,"bound",sys.argv[1],str(small_token)], text=True, capture_output=True)
    assert result.returncode == 0 and json.loads(result.stdout) == {"ok":True}, (result.returncode, result.stdout, result.stderr)
    print("PASS: loop_spec_publication_read refuses token files over 1 MiB and returns small ones unchanged")
PYTEST

echo ""
if [[ "$PYTEST_RC" -eq 0 ]]; then
  echo "PASS: the embedded Python cases above all passed"; PASS=$((PASS + 1))
else
  echo "FAIL: the embedded Python cases above (rc=$PYTEST_RC)"; FAIL=$((FAIL + 1))
fi

# --- shell-participant round trips (AC4): a valid original token writes and advances
# the generation; a token a later write has superseded is refused with "stale
# publication token" and changes nothing. ---
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pub-callers-rt.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
FW="$ROOT/lib/feature_write.py"

REPO="$WORK/repo"
mkdir -p "$REPO/docs/loop-spec/features/rt" "$REPO/tests"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name tester
cp "$ROOT/tests/fixtures/minimal-SPEC.md" "$REPO/docs/loop-spec/features/rt/SPEC.md"
git -C "$REPO" -c commit.gpgsign=false add -A
git -C "$REPO" -c commit.gpgsign=false commit -q -m base
BASE_SHA="$(git -C "$REPO" rev-parse HEAD)"
FD="$REPO/.loop-spec/features/rt"
mkdir -p "$FD"

# A fresh schema-7 skeleton: each case gets its own generation history, so an earlier
# case's writes never leak into a later one's "did the generation advance" check.
new_fd() {
  bash "$ROOT/lib/feature-init.sh" skeleton --mode single \
    --slug rt --now "2026-01-01T00:00:00Z" --style auto --title "round trip" \
    --branch feat/rt --base-sha "$BASE_SHA" --base-branch main --worktree "" \
    --prepare "" --test "true" --lint "" --typecheck "" > "$FD/feature.json"
  rm -f "$FD"/.*.lock "$FD"/*.lock "$FD/graph-checkpoints.jsonl" "$FD/events.jsonl" "$FD/graph-pause.json"
  # This fixture's SPEC.md is deliberately legacy-shaped (tests/fixtures/minimal-
  # SPEC.md, no requirements_version): strip the v1 contract a new cycle otherwise
  # carries so the first participant bootstraps legacy, same pattern as
  # tests/lib/cycle-driver.test.sh's AC6.
  jq 'del(.artifactPublication) | del(.requirementsContract)' "$FD/feature.json" > "$FD/feature.json.tmp"
  mv "$FD/feature.json.tmp" "$FD/feature.json"
}

# assert_stale_refusal NAME RC ERR: the one "was this refusal the token check, not
# something else" judgment publication_case and the spec-approve special case (which
# cannot reuse publication_case itself -- see its own comment) both need.
assert_stale_refusal() {
  local name="$1" rc="$2" err="$3"
  if [[ "$rc" -eq 0 ]]; then
    check "$name: a stale token is refused" "refused" "succeeded"
  elif grep -q 'stale publication token' <<<"$err"; then
    check "$name: a stale token is refused" "stale publication token" "stale publication token"
  else
    check "$name: a stale token is refused" "stale publication token" "$err"
  fi
}

# publication_case NAME -- CMD ARGS...
# CMD reads its token from the env pair, as every sourced shell participant does
# (lib/feature-write.sh's loop_spec_publication_begin) and as lib/graph/driver.py's
# seam does for a cycle-driver.sh command (lib/publication_participant.py). Runs CMD
# once with the feature's CURRENT token: asserts success and an advanced generation.
# Then captures a fresh token, advances the generation independently with an ordinary
# (token-less) write -- exactly how a plain, not-yet-converted participant leaves the
# NEXT token stale, the failure mode this whole contract exists to catch -- and reruns
# CMD with that now-superseded token: asserts refusal naming "stale publication token"
# and feature.json byte-identical to just before the call.
publication_case() {
  local name="$1"; shift
  [[ "${1:-}" == "--" ]] && shift
  local t0="$WORK/pc-$$-t0.json" o0="$WORK/pc-$$-o0.json" err rc0=0 gen0 gen1
  python3 "$FW" ingress "$FD" > "$t0" 2>"$WORK/pc-$$-err0"
  if [[ ! -s "$t0" ]]; then
    echo "FAIL: $name (setup ingress failed: $(cat "$WORK/pc-$$-err0"))"; FAIL=$((FAIL + 1)); return
  fi
  gen0="$(jq '.generation' "$t0")"
  err="$(LOOP_SPEC_PUBLICATION_TOKEN="$t0" LOOP_SPEC_PUBLICATION_TOKEN_OUTPUT="$o0" "$@" 2>&1 1>/dev/null)" || rc0=$?
  if [[ "$rc0" -ne 0 ]]; then
    echo "FAIL: $name (valid-token call failed, exit $rc0: $err)"; FAIL=$((FAIL + 1)); return
  fi
  gen1="$(jq -r '.artifactPublication.generation // empty' "$FD/feature.json" 2>/dev/null)"
  if [[ -n "$gen1" && "$gen1" -gt "$gen0" ]]; then
    check "$name: valid token write lands and generation advances" "true" "true"
  else
    check "$name: valid token write lands and generation advances" "advanced past $gen0" "$gen1"
  fi

  local t1="$WORK/pc-$$-t1.json" o1="$WORK/pc-$$-o1.json" tbump="$WORK/pc-$$-tbump.json" rc1=0
  python3 "$FW" ingress "$FD" > "$t1" 2>"$WORK/pc-$$-err1"
  # The unrelated bump is its own participant (task-009 strict enforcement): it
  # begins its own operation rather than bypassing the ingress token entirely.
  python3 "$FW" ingress "$FD" > "$tbump" 2>"$WORK/pc-$$-tbumperr"
  bash "$ROOT/lib/feature-write.sh" append "$FD" warnings "\"$name-bump\"" --token "$tbump" >/dev/null 2>"$WORK/pc-$$-bump.err"
  cp "$FD/feature.json" "$WORK/pc-$$-before.json"
  err="$(LOOP_SPEC_PUBLICATION_TOKEN="$t1" LOOP_SPEC_PUBLICATION_TOKEN_OUTPUT="$o1" "$@" 2>&1 1>/dev/null)" || rc1=$?
  assert_stale_refusal "$name" "$rc1" "$err"
  cmp -s "$WORK/pc-$$-before.json" "$FD/feature.json"
  check "$name: the stale attempt changed nothing" "0" "$?"
}

new_fd
publication_case "state.sh write" -- \
  bash "$ROOT/lib/graph/state.sh" write --feature-dir "$FD" --node spec --key warnings '[]' --graph "$ROOT/graph/cycle.graph.json"

new_fd
publication_case "feature-init.sh activate" -- \
  bash "$ROOT/lib/feature-init.sh" activate "$FD" spec

new_fd
bash "$ROOT/lib/graph/gate.sh" open --feature-dir "$FD" --phase spec --gate acceptance >/dev/null
# `round` shares gate.sh's one write path (write_key -> state.sh write) with `open`,
# `fail`, and `pass`; those three each change currentGate.phase to a value a REPEAT
# call refuses on its OWN business rule ("already open" / "no gate is open") before the
# token is even read, which would test that rule instead of the token. `round` has no
# such rule -- a gate that stays open accepts any number of them -- so it is the one
# gate.sh subcommand a generic valid-then-stale replay can exercise cleanly.
publication_case "gate.sh round" -- \
  bash "$ROOT/lib/graph/gate.sh" round --feature-dir "$FD"

new_fd
# phase-exit.sh's unconditional 'intent' gate (not a node egress.gates entry, so trimming
# the spec node's gates below does not skip it) requires a specApproval digest matching
# the fixture's SPEC.md Goal/Boundary text before it will pass. gates and commit are
# trimmed off the spec node's egress so this round trip proves only the token contract,
# never the semantic gates or a git commit this fixture does not need.
phase_exit_digest="$(python3 -c "
import sys
sys.path.insert(0, '$ROOT/lib')
from spec_intent import intent_digest
print(intent_digest(open('$REPO/docs/loop-spec/features/rt/SPEC.md').read()))
")"
bash "$ROOT/lib/feature-write.sh" set "$FD" specApproval "{\"sha256\":\"$phase_exit_digest\"}" >/dev/null
PHASE_EXIT_GRAPH="$WORK/graph-phase-exit.json"
jq '(.nodes[] | select(.id=="spec").egress) |= del(.gates,.required,.commit)' \
  "$ROOT/graph/cycle.graph.json" > "$PHASE_EXIT_GRAPH"
publication_case "phase-exit.sh spec" -- \
  env LOOP_SPEC_GRAPH="$PHASE_EXIT_GRAPH" bash "$ROOT/lib/phase-exit.sh" spec --feature-dir "$FD"

new_fd
publication_case "revise-state.sh ensure" -- \
  bash "$ROOT/lib/revise-state.sh" ensure "$FD/../.." rt

new_fd
publication_case "cycle-driver.sh escalate (driver fset/fappend)" -- \
  env LOOP_SPEC_CHECKPOINT_PR=0 LOOP_SPEC_HARNESS=codex bash "$ROOT/lib/cycle-driver.sh" escalate --feature-dir "$FD" --reason "round trip"

# spec approve's second call on an ALREADY-approved feature takes a verify-only
# short-circuit (verify_intent, no write at all): once specApproval is set, prepare_state
# refuses any write that changes it back ("specApproval is immutable"), so this cannot be
# a valid-then-replay pair on one fixture the way the other cases above are. Two fresh,
# never-approved fixtures instead: one proves the valid leg (approve lands, generation
# advances), a second proves the stale leg (an independent bump makes the captured token
# stale, and approve -- reaching write_operation exactly as the first fixture's did --
# refuses it and changes nothing).
new_fd
spec_approve_t0="$WORK/spec-approve.t0.json"
python3 "$FW" ingress "$FD" > "$spec_approve_t0"
spec_approve_gen0="$(jq '.generation' "$spec_approve_t0")"
LOOP_SPEC_PUBLICATION_TOKEN="$spec_approve_t0" env LOOP_SPEC_HARNESS=codex \
  bash "$ROOT/lib/cycle-driver.sh" spec approve --feature-dir "$FD" --source human >/dev/null 2>"$WORK/spec-approve-valid.err"
check "cycle_spec wrapper: valid-token approval lands" "0" "$?"
spec_approve_gen1="$(jq -r '.artifactPublication.generation // empty' "$FD/feature.json")"
if [[ -n "$spec_approve_gen1" && "$spec_approve_gen1" -gt "$spec_approve_gen0" ]]; then
  check "cycle_spec wrapper: valid token write lands and generation advances" "true" "true"
else
  check "cycle_spec wrapper: valid token write lands and generation advances" "advanced past $spec_approve_gen0" "$spec_approve_gen1"
fi

new_fd
spec_approve_t1="$WORK/spec-approve.t1.json"
python3 "$FW" ingress "$FD" > "$spec_approve_t1"
spec_approve_tbump="$WORK/spec-approve.tbump.json"
python3 "$FW" ingress "$FD" > "$spec_approve_tbump"
bash "$ROOT/lib/feature-write.sh" append "$FD" warnings '"spec-approve-bump"' --token "$spec_approve_tbump" >/dev/null
cp "$FD/feature.json" "$WORK/spec-approve.before.json"
spec_approve_rc=0
spec_approve_err="$(LOOP_SPEC_PUBLICATION_TOKEN="$spec_approve_t1" env LOOP_SPEC_HARNESS=codex \
  bash "$ROOT/lib/cycle-driver.sh" spec approve --feature-dir "$FD" --source human 2>&1 1>/dev/null)" || spec_approve_rc=$?
assert_stale_refusal "cycle_spec wrapper" "$spec_approve_rc" "$spec_approve_err"
cmp -s "$WORK/spec-approve.before.json" "$FD/feature.json"
check "cycle_spec wrapper: the stale attempt changed nothing" "0" "$?"

new_fd
publication_case "artifact-sink.sh store" -- \
  env LOOP_SPEC_ARTIFACTS_IN_PR=0 bash "$ROOT/lib/artifact-sink.sh" store "$FD" "$REPO"

# deliver.sh's happy path only ever writes the ignored delivery.json sidecar (a plain
# file replace, never through the token), so publication_case's generic "valid call
# exits 0 and the generation advances" shape does not fit it: the one write that DOES
# advance the generation -- routing tracked feature.json back to EXECUTE after every PR
# check failed -- itself exits 1 (the delivery attempt was not ok). A tiny pr-delivery
# shim forces that route so this proves the same token contract with deliver.sh's own
# exit codes instead of reusing publication_case.
DELIVER_RT="$WORK/deliver-rt"; mkdir -p "$DELIVER_RT"
git -C "$DELIVER_RT" init -q -b main
git -C "$DELIVER_RT" config user.email t@example.com
git -C "$DELIVER_RT" config user.name tester
printf 'base\n' > "$DELIVER_RT/a"
git -C "$DELIVER_RT" add a
git -C "$DELIVER_RT" -c commit.gpgsign=false commit -q -m base
DELIVER_RT_BASE="$(git -C "$DELIVER_RT" rev-parse HEAD)"
git -C "$DELIVER_RT" checkout -q -b feat/rt
printf 'feature\n' > "$DELIVER_RT/b"
git -C "$DELIVER_RT" add b
git -C "$DELIVER_RT" -c commit.gpgsign=false commit -q -m feature
DELIVER_RT_DIR="$DELIVER_RT/.loop-spec/features/rt"
mkdir -p "$DELIVER_RT_DIR"
printf '/.loop-spec/features/*/*\n!/.loop-spec/features/*/feature.json\n' > "$DELIVER_RT/.gitignore"
jq -n --arg base "$DELIVER_RT_BASE" '{schemaVersion:7,slug:"rt",feature_title:"RT",
  currentPhase:"deliver",branch:"feat/rt",baseSha:$base,baseBranch:"main",workspace:null,
  warnings:[],artifacts:{},
  artifactPublication:{version:1,generation:0,evidenceEpoch:0,migration:null,participantsVersion:1},
  delivery:{status:"pending",attemptedAt:null,finishedAt:null,targets:[]}}' > "$DELIVER_RT_DIR/feature.json"
git -C "$DELIVER_RT" add .gitignore ".loop-spec/features/rt/feature.json"
git -C "$DELIVER_RT" -c commit.gpgsign=false commit -q -m "final candidate"

DELIVER_RT_SHIM="$WORK/pr-delivery-checks-failed"
cat > "$DELIVER_RT_SHIM" <<'SHIM'
#!/usr/bin/env bash
jq -cn '{schema:1,ok:false,mode:"final",outcome:"blocked",errorCode:"checks_failed",
  error:"forced failure for round-trip test",checks:{status:"failed",required:[]}}'
exit 1
SHIM
chmod +x "$DELIVER_RT_SHIM"

deliver_rt_t0="$WORK/deliver-rt-t0.json"
python3 "$FW" ingress "$DELIVER_RT_DIR" > "$deliver_rt_t0"
deliver_rt_gen0="$(jq '.generation' "$deliver_rt_t0")"
deliver_rt_rc=0
deliver_rt_err="$(LOOP_SPEC_PUBLICATION_TOKEN="$deliver_rt_t0" LOOP_SPEC_PR_DELIVERY_BIN="$DELIVER_RT_SHIM" \
  bash "$ROOT/lib/deliver.sh" run "$DELIVER_RT_DIR" 2>&1 1>/dev/null)" || deliver_rt_rc=$?
check "deliver.sh run: valid token routes checks_failed to execute" "1" "$deliver_rt_rc"
deliver_rt_gen1="$(jq -r '.artifactPublication.generation // empty' "$DELIVER_RT_DIR/feature.json")"
if [[ -n "$deliver_rt_gen1" && "$deliver_rt_gen1" -gt "$deliver_rt_gen0" ]]; then
  check "deliver.sh run: valid token write lands and generation advances" "true" "true"
else
  check "deliver.sh run: valid token write lands and generation advances" "advanced past $deliver_rt_gen0" "$deliver_rt_gen1"
fi

jq '.currentPhase="deliver" | .delivery={status:"pending",attemptedAt:null,finishedAt:null,targets:[]}' \
  "$DELIVER_RT_DIR/feature.json" > "$DELIVER_RT_DIR/feature.json.tmp"
mv "$DELIVER_RT_DIR/feature.json.tmp" "$DELIVER_RT_DIR/feature.json"
deliver_rt_t1="$WORK/deliver-rt-t1.json"
python3 "$FW" ingress "$DELIVER_RT_DIR" > "$deliver_rt_t1"
deliver_rt_tbump="$WORK/deliver-rt-tbump.json"
python3 "$FW" ingress "$DELIVER_RT_DIR" > "$deliver_rt_tbump"
bash "$ROOT/lib/feature-write.sh" append "$DELIVER_RT_DIR" warnings '"deliver-rt-bump"' --token "$deliver_rt_tbump" >/dev/null
cp "$DELIVER_RT_DIR/feature.json" "$WORK/deliver-rt-before.json"
deliver_rt_rc1=0
deliver_rt_err1="$(LOOP_SPEC_PUBLICATION_TOKEN="$deliver_rt_t1" LOOP_SPEC_PR_DELIVERY_BIN="$DELIVER_RT_SHIM" \
  bash "$ROOT/lib/deliver.sh" run "$DELIVER_RT_DIR" 2>&1 1>/dev/null)" || deliver_rt_rc1=$?
assert_stale_refusal "deliver.sh run" "$deliver_rt_rc1" "$deliver_rt_err1"
cmp -s "$WORK/deliver-rt-before.json" "$DELIVER_RT_DIR/feature.json"
check "deliver.sh run: the stale attempt changed nothing" "0" "$?"

# --- cycle-driver.sh verification run (task-004): fill/run/review/verdict author
# against a private staged copy and publish_artifact the result, never VERIFICATION.md
# in place -- the defect this whole task fixes. A dedicated fixture, not $REPO/$FD
# above: the other cases' SPEC.md must stay byte-identical to what phase-exit.sh
# spec's digest and revise-state.sh's footprint read earlier in this file.
VERIFY_RT="$WORK/verify-rt"
mkdir -p "$VERIFY_RT"
git -C "$VERIFY_RT" init -q -b main
git -C "$VERIFY_RT" config user.email t@example.com
git -C "$VERIFY_RT" config user.name tester
git -C "$VERIFY_RT" -c commit.gpgsign=false commit -q --allow-empty -m base
VERIFY_RT_BASE="$(git -C "$VERIFY_RT" rev-parse HEAD)"
VERIFY_RT_FD="$VERIFY_RT/.loop-spec/features/rt"
VERIFY_RT_DOCS="$VERIFY_RT/docs/loop-spec/features/rt"
mkdir -p "$VERIFY_RT_FD" "$VERIFY_RT_DOCS"
cat > "$VERIFY_RT_DOCS/SPEC.md" <<'SPEC'
---
footprint: [a.txt]
criteria:
  GE-001: "true"
---
# verify round trip

## Success criteria

### Good Enough

- [ ] `true` exits 0
SPEC
verify_rt_verification_skeleton() {
  cat > "$VERIFY_RT_DOCS/VERIFICATION.md" <<'VERIF'
# verify round trip - Verification

## Acceptance criteria

| # | Criterion | Status | Evidence |
|---|-----------|--------|----------|

## Code review

**Reviewer:** code-reviewer (inherit)

### Findings

none

## Final test suite

```
(not yet run)
```
VERIF
}
new_verify_rt_fd() {
  bash "$ROOT/lib/feature-init.sh" skeleton --mode single \
    --slug rt --now "2026-01-01T00:00:00Z" --style auto --title "verify round trip" \
    --branch feat/rt --base-sha "$VERIFY_RT_BASE" --base-branch main --worktree "" \
    --prepare "" --test "true" --lint "" --typecheck "" > "$VERIFY_RT_FD/feature.json"
  rm -f "$VERIFY_RT_FD"/.*.lock "$VERIFY_RT_FD"/*.lock "$VERIFY_RT_FD/graph-checkpoints.jsonl" "$VERIFY_RT_FD/events.jsonl" "$VERIFY_RT_FD/graph-pause.json"
  # This fixture's SPEC.md is deliberately legacy-shaped (the criteria: frontmatter
  # map, not requirements_version): strip the v1 contract a new cycle otherwise
  # carries so the first participant bootstraps legacy, same pattern as
  # tests/lib/cycle-driver.test.sh's AC6.
  jq 'del(.artifactPublication) | del(.requirementsContract)' "$VERIFY_RT_FD/feature.json" > "$VERIFY_RT_FD/feature.json.tmp"
  mv "$VERIFY_RT_FD/feature.json.tmp" "$VERIFY_RT_FD/feature.json"
}

new_verify_rt_fd
verify_rt_verification_skeleton
verify_rt_t0="$WORK/verify-rt-t0.json"
python3 "$FW" ingress "$VERIFY_RT_FD" > "$verify_rt_t0"
verify_rt_gen0="$(jq '.generation' "$verify_rt_t0")"
verify_rt_rc=0
verify_rt_err="$(LOOP_SPEC_PUBLICATION_TOKEN="$verify_rt_t0" env LOOP_SPEC_HARNESS=codex \
  bash "$ROOT/lib/cycle-driver.sh" verification run --feature-dir "$VERIFY_RT_FD" 2>&1 1>/dev/null)" || verify_rt_rc=$?
check "cycle-driver.sh verification run: a valid token's run exits 0" "0" "$verify_rt_rc"
verify_rt_gen1="$(jq -r '.artifactPublication.generation // empty' "$VERIFY_RT_FD/feature.json")"
if [[ -n "$verify_rt_gen1" && "$verify_rt_gen1" -gt "$verify_rt_gen0" ]]; then
  check "cycle-driver.sh verification run: valid token write publishes and the generation advances" "true" "true"
else
  check "cycle-driver.sh verification run: valid token write publishes and the generation advances" "advanced past $verify_rt_gen0" "$verify_rt_gen1"
fi
check "cycle-driver.sh verification run: the real VERIFICATION.md carries the row, never a private staged copy" \
  "1" "$(grep -c '^| GE-001 | .*true.* | PASS |' "$VERIFY_RT_DOCS/VERIFICATION.md")"

new_verify_rt_fd
verify_rt_verification_skeleton
verify_rt_t1="$WORK/verify-rt-t1.json"
python3 "$FW" ingress "$VERIFY_RT_FD" > "$verify_rt_t1"
verify_rt_tbump="$WORK/verify-rt-tbump.json"
python3 "$FW" ingress "$VERIFY_RT_FD" > "$verify_rt_tbump"
bash "$ROOT/lib/feature-write.sh" append "$VERIFY_RT_FD" warnings '"verify-rt-bump"' --token "$verify_rt_tbump" >/dev/null
cp "$VERIFY_RT_FD/feature.json" "$WORK/verify-rt-before.json"
cp "$VERIFY_RT_DOCS/VERIFICATION.md" "$WORK/verify-rt-verification-before.md"
verify_rt_rc1=0
verify_rt_err1="$(LOOP_SPEC_PUBLICATION_TOKEN="$verify_rt_t1" env LOOP_SPEC_HARNESS=codex \
  bash "$ROOT/lib/cycle-driver.sh" verification run --feature-dir "$VERIFY_RT_FD" 2>&1 1>/dev/null)" || verify_rt_rc1=$?
assert_stale_refusal "cycle-driver.sh verification run" "$verify_rt_rc1" "$verify_rt_err1"
cmp -s "$WORK/verify-rt-before.json" "$VERIFY_RT_FD/feature.json"
check "cycle-driver.sh verification run: the stale attempt changed feature.json nothing" "0" "$?"
cmp -s "$WORK/verify-rt-verification-before.md" "$VERIFY_RT_DOCS/VERIFICATION.md"
check "cycle-driver.sh verification run: the stale attempt left VERIFICATION.md unchanged" "0" "$?"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
