# Cycle startup probes -- model + Workflow (reference)

Extracted verbatim from `skills/cycle/SKILL.md`; the SKILL stub points here. Apply as written.

### Step 3.5 - Model probe

Model selection is fixed (see `skills/shared/model-matrix.md`): the unique alias set is always `{opus, sonnet}` (harness aliases — the Agent tool's `model` parameter accepts aliases, not literal IDs).

**pi harness: skip this probe entirely** (`harness != "claude"` in the preflight
blob). The probe pre-flights `Agent` dispatches and pi has no `Agent` tool; model
failures surface loudly on the first loop-fleet dispatch instead. Do not write
`modelsProbedAt`. See `skills/shared/pi-harness.md`. The same skip applies under
opencode: the aliases are Claude Code-only (per-role models live in the generated
agent files there), so failures surface on the first task or loop-fleet dispatch.
See `skills/shared/opencode-harness.md`.

**Probe cache (speed):** the probe result is cached in `.loop-spec/runtime.json`
(`modelsProbedAt`, ISO-8601). Skip the probe entirely — zero Agent dispatches —
when either holds:

```bash
skip_probe=false
[[ "${LOOP_SPEC_SKIP_HEALTHCHECK:-}" == "1" ]] && skip_probe=true
probed_at=$(jq -r '.modelsProbedAt // empty' .loop-spec/runtime.json 2>/dev/null || true)
if [[ -n "$probed_at" ]]; then
  age=$(( $(date -u +%s) - $(python3 -c "import sys,datetime;print(int(datetime.datetime.strptime(sys.argv[1],'%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc).timestamp()))" "$probed_at" 2>/dev/null || echo 0) ))
  [[ "$age" -lt 86400 ]] && skip_probe=true   # probed within the last 24h
fi
```

A model-policy failure surfaces identically on the first real dispatch, so the
cache trades nothing for the saved startup latency. On probe success, write
`modelsProbedAt` into `runtime.json` (merged with the workflow probe below).

When not skipped, dispatch one probe Agent per unique model (parallel, single tool message):

```
Parallel:
  Agent({description: "Model probe: opus", subagent_type: "loop-spec:spec-writer", model: "opus",   prompt: "Reply with the single word: ok"})
  Agent({description: "Model probe: sonnet", subagent_type: "loop-spec:implementer", model: "sonnet", prompt: "Reply with the single word: ok"})
```

Retry each on transient error (2x, 2s backoff). On hard failure:
```
loop-spec health check FAILED
  Model: {model_id}
  Error: {error}
  Suggested fix: update CLAUDE.md model policy to allow {model_id}
```
Then abort.

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
