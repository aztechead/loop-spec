# Cycle Steps 5.9 and 6 invoke — graph step, activate, Skill dispatch (reference)

Extracted verbatim from `skills/cycle/SKILL.md`; the SKILL stub points here. Apply
as written. Item numbering continues into `references/phase-loop.md` for the return
and next-iteration half.

Contents: Step 5.9 `run.sh --step` loop, `feature-init.sh activate`, title/preset
backfill · Step 6 invoke (`phaseHandoff`, activate, `cycle-result.sh begin`,
extension points, `Skill(...)` dispatch).

### Step 5.9 - Activate the current phase's model routing

Every phase skill reads `feature.models.<role>` as the selector. Add a `model`
key only when it is one of the four Agent aliases **and** the spawn is nameless
(a one-shot Agent, the no-teams fallback, or implicit-team `oneshot`). When it is
`inherit`, **emit no `model` key at all**. Named implicit-team spawns also omit
`model`: they inherit the session regardless
(`skills/shared/implicit-team-mode.md`). The Agent tool rejects the literal
string `inherit` with `InputValidationError` — inheritance is expressed by omission
(`skills/shared/harness-call-contracts.md`). Immediately
before a phase launch, `feature-init.sh activate` resolves and persists the exact
map those Agent calls consume:

1. task-level `model` / `modelTier` (where that rung supports it);
2. explicit `LOOP_SPEC_MODEL_<ROLE>`;
3. explicit `LOOP_SPEC_PHASE_MODEL_<PHASE>`;
4. canonical role default.

The activation also persists all seven configured phase overrides in
`feature.phaseModels`. This is the handoff contract used by a Claude Code CLI or
Python Agent SDK supervisor to select the main model for the next fresh phase
query. An unset phase entry is `null` and leaves that query on its ordinary
`CLAUDE_MODEL` / session default.

Older features either lack these blocks or carry a stale map from the removed
preset scheme. Activate the recorded current phase on every new run/resume and
drop vestigial `preset` and `tier` fields:

Sequencing is owned by the declared graph (`graph/cycle.graph.json`), never a bare
`currentPhase` read — `docs/loop-spec/features/gdd/REMEDIATION-CONTRACT.md` sec 1-6.
`lib/graph/run.sh --step` processes exactly one node and returns its JSON dispatch
descriptor (`{node, label, kind, body, effort, nextEdge, terminal, paused}`); it already
resumes from wherever the last step/pause/checkpoint left off (contract sec 5), so this
is also the resume path — there is no separate manual `checkpoint.sh latest` + `--resume`
call to make. The engine dispatches in-process anything it can execute itself (`function`/
`gate` bodies, a real nested `subgraph` run, an unadmitted `human` node's skip-and-route);
this loop only stops at an `agent` node (this phase's own dispatch — the orchestrator, not
the engine, drives an agent through `Skill(...)`), an admitted `human` node (exit 4,
pause), a route abort (exit 5), or the graph's terminal node. Entering or leaving a
working-phase node also emits `phase_start` / `phase_end` on stderr (the JSON
descriptor stays on stdout so this snippet's `step_json=$(...)` capture stays
parseable). This exact snippet resolves
`currentPhase` for dispatch both here (session entry) and at the bottom of Step 6
(continuing after a phase returns) — same snippet, same call, one authority:

```bash
feat_dir=".loop-spec/features/${slug}"
fjson="${feat_dir}/feature.json"
GRAPH="${CLAUDE_SKILL_DIR}/../../graph/cycle.graph.json"
while :; do
  set +e
  step_json="$(bash "${CLAUDE_SKILL_DIR}/../../lib/graph/run.sh" --step \
    --feature-dir "$feat_dir" "$GRAPH")"
  step_rc=$?
  set -e
  case "$step_rc" in
    4)
      echo "loop-spec: paused at human node $(jq -r '.node' <<<"$step_json") -- resumable; re-invoke /loop-spec:cycle to continue." >&2
      exit 0
      ;;
    5)
      echo "loop-spec: graph routing aborted -- a node had route edges and none was satisfied, with no routeDefault. See stderr above for the probe diagnostics." >&2
      exit 1
      ;;
    0) ;;
    *)
      echo "loop-spec: run.sh --step failed unexpectedly (exit $step_rc)" >&2
      exit 1
      ;;
  esac
  [[ "$(jq -r '.terminal' <<<"$step_json")" == "true" ]] && break
  [[ "$(jq -r '.kind' <<<"$step_json")" == "agent" ]] && break
  # function/gate/subgraph/skipped-human: the engine already dispatched it
  # in-process. Nothing for the orchestrator to do here -- step again.
done
currentPhase="$(jq -r '.node' <<<"$step_json")"
current_phase="$currentPhase"
currentLabel="$(jq -r '.label' <<<"$step_json")"
node_effort="$(jq -r '.effort' <<<"$step_json")"
# The label is what the node MEANS; the id is what the graph calls it. Announce
# both so a resumed run reads as work rather than as a node identifier.
if [[ "$(jq -r '.terminal' <<<"$step_json")" == "true" ]]; then
  echo "loop-spec: graph traversal reached its terminal node -- ${currentLabel} (${currentPhase})."
else
  echo "loop-spec: ${currentLabel} (${currentPhase}, effort ${node_effort})."
  bash "${CLAUDE_SKILL_DIR}/../../lib/feature-init.sh" activate \
    "$feat_dir" "$current_phase"
fi
if [[ "$(jq 'has("preset") or has("tier")' "$fjson")" == "true" ]]; then
  new_json="$(jq 'del(.preset) | del(.tier)' "$fjson")"
  bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" "$feat_dir" "$new_json"
  echo "Dropped legacy tier/preset fields."
fi

# Backfill feature_title (pre-2.4.0 features lack it). It is the IMMUTABLE original
# goal that the ITERATE judge scores against; without it the judge silently falls back
# to SPEC.md -- the exact drift the dual oracle exists to prevent. The slug is the only
# available (lossy) stand-in on old features; never overwrite an existing value.
if [[ "$(jq -r '.feature_title // ""' "$fjson")" == "" ]]; then
  new_json="$(jq '.feature_title = .slug' "$fjson")"
  bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" "$feat_dir" "$new_json"
  echo "Backfilled feature_title from slug (pre-2.4.0 feature; lossy stand-in for the original goal)."
fi
```

### Step 6 - Route to phase

Sequencing is owned by the declared graph. `currentPhase` for this iteration was
already resolved by the Step 5.9 `run.sh --step` snippet — that is the single
authority for phase successors, ITERATE rewind targets, DELIVER's CI-remediation
path, critique subgraphs, and human pauses; this step does not re-derive it. Resume
is that same snippet's built-in pause-record/checkpoint-ledger/`currentPhase`
resolution (contract sec 5) — not a separate prose scan-and-infer, and not a manual
`checkpoint.sh latest` + `--resume` call made anywhere in this skill.

Exit 4 from `run.sh --step` is a human-node pause (resumable; the snippet already
returned to the user). Exit 0 with `.terminal == true` is a completed traversal —
the graph reached its `completed` node, which the engine's own dispatch of
`lib/cycle-result.sh` already published as the terminal result; jump to "On
completion" below. Exit 0 with `.kind == "agent"` is this step's normal case: the
snippet stopped at a real phase to dispatch.

Consume `$node_effort` as model-independent guidance. It never chooses a model:
Claude Code and OpenCode may expose different catalogs, and both inherit the model that
launched the session by default. For `system1`, keep the phase direct and avoid optional
extra review rounds. For `system2`, state the assumptions and check their evidence before
committing to the phase result. Every declared gate runs in either mode.

The cycle does NOT create the phase team. Each phase skill owns its own team lifecycle: `TeamCreate` at phase start, `TeamDelete` + clear `currentTeamName` at phase end. This keeps team rosters phase-specific (each phase has different teammates) and avoids double-`TeamCreate` errors.

Resolve and persist the main-context policy before invoking a phase. The inline token
(`phase:fresh` or `phase:continuous`) wins, then `LOOP_SPEC_PHASE_HANDOFF=0|1`, then
the value already stored in `feature.json.phaseHandoff`; the default is `false`.
Reject any other environment value. Persist the resolved boolean with
`feature-write.sh` so a bare resume command keeps the same policy. This policy is
orthogonal to subagents: it replaces the phase orchestrator between phases, while
one-shot role agents may still run inside each phase.

```bash
feature_dir=".loop-spec/features/${slug}"
phase_handoff="$(jq -r '.phaseHandoff // false' "$feature_dir/feature.json")"
case "${LOOP_SPEC_PHASE_HANDOFF:-}" in
  "") ;;
  0) phase_handoff=false ;;
  1) phase_handoff=true ;;
  *) echo "loop-spec: LOOP_SPEC_PHASE_HANDOFF must be 0 or 1." >&2; exit 2 ;;
esac
case "$(jq -r '.phase_mode // empty' <<<"$inv")" in
  fresh) phase_handoff=true ;;
  continuous) phase_handoff=false ;;
esac
bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" set \
  "$feature_dir" phaseHandoff "$phase_handoff"
```

Node bodies remain the phase skills. The engine selects the next node; the lead
dispatches `Skill(loop-spec:{currentPhase})` for agent nodes and reacts to the
return. DELIVER remains the sole owner of push, PR reconciliation, required
checks, and readiness.

Cycle's responsibility after the engine names a node is to invoke that phase skill and react to its return:

1. **Invoke phase skill** (with the watchdog stamp):
   Before every invocation—including continuous routing after a prior phase
   returns—activate that phase's effective model map. This call is mandatory; do
   not invoke a phase against the previous phase's map. Since every team,
   implicit-team (named inherit or nameless oneshot), and one-shot fallback launch
   reads `feature.models.<role>`,
   this is the enforcement point that makes phase routing apply to authors,
   implementers, verifiers, and phase-gate reviewers alike. Named implicit-team
   spawns still inherit the session model; an alias must take the oneshot path
   (`skills/shared/implicit-team-mode.md`).
   ```bash
   feature_dir=".loop-spec/features/${slug}"
   bash "${CLAUDE_SKILL_DIR}/../../lib/feature-init.sh" activate \
     "$feature_dir" "$currentPhase"
   feature_json="$(cat "$feature_dir/feature.json")"
   ```
   DELIVER owns all pre-delivery candidate mutation through
   `lib/finalize-delivery-candidate.sh`, called by `lib/deliver.sh`. The helper finalizes
   only the named retro/rules/digest artifacts before first observation and becomes a
   strict no-op when an eligible sidecar target already binds the retry SHA. The cycle
   must not create its own pre-DELIVER commits or duplicate the binding predicate.
   ```bash
   # DELIVER has deterministic per-command and total check timeouts; avoid a
   # tracked watchdog write after its candidate SHA was finalized.
   if [[ "$currentPhase" != "deliver" ]]; then
     bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" set \
       ".loop-spec/features/${slug}" currentPhaseStartedAt "\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
   fi
   # phase_start/phase_end are emitted by run.sh --step at the node
   # transition (lib/graph/engine.py). Do not re-emit here — a second copy
   # is noise, and this call is the compliance gap that hid the console bar
   # when a coder ran the phase inline.
   bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-result.sh" begin \
     --result-root "$repo_root" --cycle-type full --title "$title" --slug "$slug" \
     --branch "feat/${slug}" --base-branch "$base_branch" \
     --feature-dir "$(cd ".loop-spec/features/${slug}" && pwd -P)" \
     --phase "$currentPhase" --autonomous "$active_autonomous"
   ```
   Then load anything this project declared for the phase. Both calls are silent in a
   project that declared nothing, which is the normal case:
   ```bash
   bash "${CLAUDE_SKILL_DIR}/../../lib/extension-points.sh" instructions "$currentPhase" prepend
   bash "${CLAUDE_SKILL_DIR}/../../lib/extension-points.sh" facts
   ```
   Treat each emitted instruction as a directive for this phase, and each `fact=file`
   path as standing context to read before the phase begins. Run the `append` instructions
   after the skill returns. These are accelerators: they may shape how work is done, never
   whether a gate passes, and the path fails open — no output means no extensions.

   The Step 5.9 `--step` call already printed the greppable boundary
   (`LOOP_SPEC_PHASE_START` / `[{CURRENTPHASE}] start` on stderr). The matching
   `done` line is printed by the next `--step`, when the engine leaves this
   node. Do not print them by hand — `skills/shared/report-style.md`.
   ```
   Skill(loop-spec:{currentPhase})
   ```
   Never AskUserQuestion as a wait (`skills/shared/harness-call-contracts.md`) while
   a phase Agent or the DELIVER controller is running. Dispatch, then stop; the
   harness resumes this turn.
   `{currentPhase}` is read from the in-memory `feature_json`. Team-capable phases own
   their team lifecycle; SPEC, ITERATE, and DELIVER run on the main thread. Every phase
   advances `currentPhase` through `lib/feature-write.sh`.

