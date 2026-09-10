#!/usr/bin/env bash
# Executable publication participants retain the token that admitted their work.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PYTHONPATH="$ROOT/lib" python3 - "$ROOT" <<'PYTEST'
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
