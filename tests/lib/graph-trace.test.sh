#!/usr/bin/env bash
# Unit tests for lib/graph/trace.sh — node-stamped events, never-abort.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/lib/graph/trace.sh"
WORK="${TMPDIR:-/tmp}/loop-spec-graph-trace.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/feat" "$WORK/bin"
PASS=0; FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"; FAIL=$((FAIL + 1))
  fi
}

[[ -f "$SCRIPT" ]] || { echo "FAIL: missing $SCRIPT"; exit 1; }

jq -n '{slug:"gdd-trace",schemaVersion:7}' > "$WORK/feat/feature.json"

# --- stamped fields present ---
rc=0
bash "$SCRIPT" emit "$WORK/feat" dispatch \
  --phase execute \
  --node execute \
  --edge 'chain:plan->execute' \
  --probe lib/effort-probe.sh \
  --probe-reason "mode=system2 reason=width:4" \
  --effort system2 \
  --data '{"role":"implementer"}' || rc=$?
check "emit exit 0" "0" "$rc"
last="$(tail -1 "$WORK/feat/events.jsonl")"
check "valid JSONL" "0" "$(printf '%s' "$last" | jq . >/dev/null 2>&1; echo $?)"
check "node field" "execute" "$(jq -r '.node' <<<"$last")"
check "edge field" "chain:plan->execute" "$(jq -r '.edge' <<<"$last")"
check "probe field" "lib/effort-probe.sh" "$(jq -r '.probe' <<<"$last")"
check "probeReason field" "mode=system2 reason=width:4" "$(jq -r '.probeReason' <<<"$last")"
check "effort field" "system2" "$(jq -r '.effort' <<<"$last")"

# --- never-abort with failing stub writer ---
printf '#!/usr/bin/env bash\necho boom >&2\nexit 1\n' > "$WORK/bin/events.sh"
chmod +x "$WORK/bin/events.sh"
rc=0
err="$(LOOP_SPEC_EVENTS="$WORK/bin/events.sh" bash "$SCRIPT" emit "$WORK/feat" dispatch \
  --node x --edge y --probe z --probe-reason r --effort system1 2>&1)" || rc=$?
check "failing writer still exit 0" "0" "$rc"
check "failing writer warns" "1" "$([[ "$err" == *"warning"* || "$err" == *"boom"* ]] && echo 1 || echo 0)"

# --- run-digest still parses augmented records ---
# Reset with real events writer for a clean sequence
rm -f "$WORK/feat/events.jsonl"
bash "$SCRIPT" emit "$WORK/feat" phase_start --phase execute \
  --node execute --edge 'chain:plan->execute' --probe none --probe-reason none --effort system2 >/dev/null
bash "$SCRIPT" emit "$WORK/feat" phase_end --phase execute --data '{"next":"verify"}' \
  --node execute --edge 'chain:execute->verify' --probe none --probe-reason none --effort system2 >/dev/null
# run-digest should not choke (exit 0 always)
digest_rc=0
bash "$ROOT/lib/run-digest.sh" append "$WORK/feat" --out-dir "$WORK/digests" >/dev/null 2>&1 || digest_rc=$?
check "run-digest parses stamped events" "0" "$digest_rc"

# --- reconstruction of node/edge sequence ---
rm -f "$WORK/feat/events.jsonl"
bash "$SCRIPT" emit "$WORK/feat" dispatch --node spec --edge 'entry->spec' --probe none --probe-reason none --effort system2 >/dev/null
bash "$SCRIPT" emit "$WORK/feat" dispatch --node discuss --edge 'chain:spec->discuss' --probe none --probe-reason none --effort system2 >/dev/null
bash "$SCRIPT" emit "$WORK/feat" dispatch --node plan --edge 'chain:discuss->plan' --probe none --probe-reason none --effort system2 >/dev/null
seq="$(jq -r '[.node, .edge] | @tsv' "$WORK/feat/events.jsonl" | paste -sd'|' -)"
expected="spec	entry->spec|discuss	chain:spec->discuss|plan	chain:discuss->plan"
check "reconstruct traversed sequence" "$expected" "$seq"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
