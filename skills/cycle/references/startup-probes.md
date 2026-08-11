# Cycle startup probes -- model + Workflow (reference)

Extracted verbatim from `skills/cycle/SKILL.md`; the SKILL stub points here. Apply as written.

### Step 3.5 - Model probe

Resolve the complete selector set from the same executable source used at phase
entry. This includes the portable `inherit` default plus every explicit
per-role and per-phase override:

```bash
required_models="$(bash "${CLAUDE_SKILL_DIR}/../../lib/feature-init.sh" all-models)" || {
  echo "loop-spec: model routing is misconfigured; startup cannot resolve the selector set." >&2
  exit 2
}
```

The exit status is load-bearing. `all-models` prints nothing and exits non-zero when
any `LOOP_SPEC_PHASE_MODEL_<PHASE>` or `LOOP_SPEC_MODEL_<ROLE>` value is not a harness
supported selector. Relay that configuration error verbatim and stop; never continue
with a partial set, because phase-entry activation would fail later anyway.

The Agent tool can probe only its four aliases. Ask the same executable authority
for that subset; never send `inherit` or a full ID to `Agent({model:})`:

```bash
agent_probe_models="$(
  bash "${CLAUDE_SKILL_DIR}/../../lib/feature-init.sh" agent-probe-models
)" || {
  echo "loop-spec: model routing is misconfigured; startup cannot resolve Agent probe aliases." >&2
  exit 2
}
```

`inherit` needs no availability probe: omission is the supported operation and
the first real role dispatch uses the same operation. A full ID is valid only for
a fresh Claude CLI/SDK phase launcher and is checked by that launcher; role-level
full IDs fail in `feature-init.sh` before this step because Agent cannot consume
them.

**pi harness: skip this probe entirely** (`harness != "claude"` in the preflight
blob). The probe pre-flights `Agent` dispatches and pi has no `Agent` tool; model
failures surface loudly on the first loop-fleet dispatch instead. Do not write
`modelsProbedAt`. See `skills/shared/pi-harness.md`. The same skip applies under
OpenCode: per-role models live in the generated agent files there, so failures surface
on the first task or loop-fleet dispatch.
See `skills/shared/opencode-harness.md`.

**Probe cache (speed):** the probe result is cached in `.loop-spec/runtime.json`
(`modelsProbedAt`, ISO-8601, and `modelsProbed`, the sorted selector array). Skip the
probe entirely—zero Agent dispatches—when the explicit kill switch is set, or
when both the age and exact selector set match:

```bash
skip_probe=false
[[ "${LOOP_SPEC_SKIP_HEALTHCHECK:-}" == "1" ]] && skip_probe=true
[[ "$agent_probe_models" == "[]" ]] && skip_probe=true
probed_at=$(jq -r '.modelsProbedAt // empty' .loop-spec/runtime.json 2>/dev/null || true)
probed_models=$(jq -c '.modelsProbed // []' .loop-spec/runtime.json 2>/dev/null || echo '[]')
if [[ -n "$probed_at" && "$probed_models" == "$(jq -c . <<<"$required_models")" ]]; then
  age=$(( $(date -u +%s) - $(python3 -c "import sys,datetime;print(int(datetime.datetime.strptime(sys.argv[1],'%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc).timestamp()))" "$probed_at" 2>/dev/null || echo 0) ))
  [[ "$age" -lt 86400 ]] && skip_probe=true   # probed within the last 24h
fi
```

A model-policy failure surfaces identically on the first real dispatch, so the
cache trades nothing for the saved startup latency. On probe success, write
`modelsProbedAt` and `modelsProbed = required_models` into `runtime.json` (merged
with the workflow probe below).

When not skipped, read the aliases from `agent_probe_models` and dispatch one probe
Agent per value (parallel, single tool message). Every call passes a value proven
to belong to the Agent enum:

```
Parallel:
  for model_selector in agent_probe_models:
    Agent({
      description: "Model probe: {model_selector}",
      subagent_type: "loop-spec:spec-writer",
      model: model_selector,
      prompt: "Reply with the single word: ok"
    })
```

Retry each on transient error (2x, 2s backoff). On hard failure:
```
loop-spec health check FAILED
  Model: {model_id}
  Error: {error}
  Suggested fix: update CLAUDE.md model policy to allow {model_id}
```
Then abort.

After every probe succeeds, persist the exact cache key atomically:

```bash
mkdir -p .loop-spec
runtime_tmp=".loop-spec/runtime.json.tmp"
jq -n \
  --argjson prior "$(cat .loop-spec/runtime.json 2>/dev/null || echo '{}')" \
  --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson models "$required_models" \
  '$prior + {modelsProbedAt:$now, modelsProbed:$models}' > "$runtime_tmp"
mv "$runtime_tmp" .loop-spec/runtime.json
```

Set `sonnet_1m_available = false` (1M context probe removed; defaults to false; the skill will use standard context windows).

### Workflow availability probe

After the model health-check, write `.loop-spec/runtime.json` recording (a) whether the `Workflow` tool is available, gated deterministically on the Claude Code version (`Workflow` ships in CC `>= 2.1.154`; do not rely on model self-introspection), and (b) whether the operator opted into the EXECUTE workflow rung:

```bash
mkdir -p .loop-spec
wf="$(bash "${CLAUDE_SKILL_DIR}/../../lib/workflow-availability.sh")"
optin=false
[[ "${LOOP_SPEC_EXECUTE_WORKFLOW:-}" == "1" ]] && optin=true
# Merge-write: preserves modelsProbedAt (Step 3.5 cache) across cycles.
python3 -c "
import json, sys, os
path = '.loop-spec/runtime.json'
data = {}
if os.path.exists(path):
    try:
        data = json.load(open(path))
    except Exception:
        data = {}
data['workflowsAvailable'] = sys.argv[1] == 'true'
data['workflowExecuteOptIn'] = sys.argv[2] == 'true'
data['teamsAvailable'] = sys.argv[3] == 'true'
data['teamsMode'] = sys.argv[4]   # none | explicit | implicit
data['harness'] = sys.argv[5]     # claude | pi (lib/harness.sh detect)
json.dump(data, open(path, 'w'))
" "$wf" "$optin" "$teams_available" "$teams_mode" "$(bash "${CLAUDE_SKILL_DIR}/../../lib/harness.sh" detect)"
```

`teamsMode` is the authoritative dispatch selector; `teamsAvailable` is kept as the
`teamsMode != "none"` convenience boolean that existing phase branches already read.

`lib/workflow-availability.sh` gates on the CC version; set `LOOP_SPEC_WORKFLOWS_AVAILABLE=1|0` to force it (testing).

`workflowExecuteOptIn` gates the heaviest EXECUTE rung. EXECUTE's concurrency ladder
(`skills/shared/tier-matrix.md`) selects subagent or agent-team dispatch by DAG width on
its own; it escalates to a Workflow DAG **only** when the operator sets
`LOOP_SPEC_EXECUTE_WORKFLOW=1` AND the DAG is wide enough (`W >= t_wf`) AND the
`Workflow` tool is available. This honors the Anthropic guidance that Workflow runs only
on explicit opt-in. With the flag unset, EXECUTE never dispatches a Workflow even on a
very wide DAG; it tops out at the agent-team rung. (The flag does not affect the
opportunistic fan-out workflows in PLAN/VERIFY/map-codebase, which remain gated on
`workflowsAvailable` alone.)

Then invoke the permission check hook (non-fatal advisory):

```bash
bash "${CLAUDE_SKILL_DIR}/../../hooks/pre-cycle-permission-check.sh"
```

`workflowsAvailable` is `true` on Claude Code `>= 2.1.154` (where `Workflow` is
supported), else `false`. The cycle proceeds regardless; fan-out skills read
`runtime.json` to decide their dispatch path. See `skills/shared/dispatch-fanout.md`.
