# Cycle Step 2 — startup health-check (reference)

Extracted verbatim from `skills/cycle/SKILL.md` Step 2; the SKILL stub points here.
Apply as written.

Contents: `LOOP_SPEC_MAX_PARALLEL_SUBAGENTS` validation · `teams_mode` from the
preflight blob · harness overlays (ADK / opencode / Codex) · guarded-team-op
contract · deferred-tool rescue.

### Step 2 - Startup health-check

Validate deployment fan-out policy before probing capabilities:

```bash
if [[ -n "${LOOP_SPEC_MAX_PARALLEL_SUBAGENTS:-}" \
      && ! "$LOOP_SPEC_MAX_PARALLEL_SUBAGENTS" =~ ^[1-9][0-9]*$ ]]; then
  echo "loop-spec: LOOP_SPEC_MAX_PARALLEL_SUBAGENTS must be a positive integer." >&2
  exit 2
fi
```

Probe agent-teams availability. Teams are an ACCELERATOR, not a prerequisite:
when they are unavailable the cycle still runs end-to-end on the documented
fallbacks (DISCUSS/PLAN/VERIFY: one-shot subagent fallback per the **No-teams
fallback** contract below; EXECUTE: loop-fleet or subagent rung). Do NOT abort.

Agent teams come in **two harness generations**, and the cycle must route to the right
one. Claude Code **>= 2.1.178** removed the `TeamCreate` / `TeamDelete` tools: every
session now has one implicit team and teammates are spawned directly via `Agent({name})`.
Earlier versions use the explicit `TeamCreate` / `TeamDelete` roster model. `lib/teams-capability.sh`
resolves which generation is live into a single **mode** word (deterministic, version-gated —
mirrors the `Workflow` probe; does not rely on model self-introspection):

```bash
teams_mode="$(jq -r '.teams.mode' <<<"$pf")"          # none | explicit | implicit
teams_available="$(jq -r '.teams.available' <<<"$pf")"

case "$teams_mode" in
  none)
    loops_hint="subagent fallback"
    command -v "$(bash "${CLAUDE_SKILL_DIR}/../../lib/harness.sh" cli)" >/dev/null 2>&1 && loops_hint="loop-fleet + subagent fallback"
    echo "loop-spec: agent teams off (CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS != 1)."
    echo "  Continuing with ${loops_hint}. For persistent phase teams: export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1." ;;
  implicit)
    echo "loop-spec: agent teams on (implicit-team model, CC >= 2.1.178)."
    echo "  Named inherit teammates spawn via Agent({name}); a role alias spawns a nameless one-shot Agent. TeamCreate/TeamDelete are not used. See skills/shared/implicit-team-mode.md." ;;
  explicit)
    echo "loop-spec: agent teams on (explicit-team model, CC < 2.1.178). Per-phase TeamCreate/TeamDelete." ;;
esac
```

**`teams_mode` decides every phase's dispatch path** — per the Dispatch convention
section above. Harness overlays when `teams_mode == "none"` (the preflight blob's
`harness.name` is always `none`-mode on these):

- `adk`: one-shot dispatches run through the bridge's `dispatch_subagent` tool — apply
  **`skills/shared/adk-harness.md`** on top (same call shape, role names without the
  `loop-spec:` prefix, model probe skipped).
- `opencode`: dispatches run natively through opencode's `task` tool — apply
  **`skills/shared/opencode-harness.md`** on top (agent ids spelled `loop-spec-<role>`,
  model probe skipped).
- `codex`: dispatches run through Codex `spawn_agent` — apply
  **`skills/shared/codex-harness.md`** on top (agent ids spelled `loop-spec-<role>`,
  model probe skipped).

**Guarded-team-op contract (CRITICAL — explicit-mode safety net):** the version gate is
deterministic, but a non-standard harness could still disagree with it. So in **`explicit`
mode only**, whenever a phase issues its first `TeamCreate` (or any team op) and it throws
`No such tool available` (or any "tool not found"/unknown-tool error from a team primitive),
treat it as a capability refutation, NOT a fatal error:

1. If the harness is the modern one (the tools were removed, not the flag), re-resolve via
   `LOOP_SPEC_TEAMS_MODE=implicit` and re-run the phase per `skills/shared/implicit-team-mode.md`.
   Otherwise downgrade to `none`. Merge-write the corrected mode:
   ```bash
   python3 -c "import json,sys;p='.loop-spec/runtime.json';d=json.load(open(p));m=sys.argv[1];d['teamsMode']=m;d['teamsAvailable']=(m!='none');json.dump(d,open(p,'w'))" implicit   # or: none
   ```
2. Print: `loop-spec: explicit team tools not exposed by this harness; switching to <implicit-team | one-shot Agent> dispatch.`
3. Re-run the current phase on the corrected path. Do NOT re-attempt the explicit team op in this session.

In `implicit` and `none` mode the contract is a no-op — those phases never call `TeamCreate`,
so there is nothing to refute. This keeps a version/tool-surface disagreement self-healing on
the first op instead of a hard stop mid-phase.

**Deferred-tool rescue (applies in `implicit` AND `explicit` mode, BEFORE any refutation):**
modern harnesses may expose team primitives (`SendMessage`, `TaskCreate`, `TaskUpdate`,
`TaskList`, `TaskGet`) as **deferred tools** — the tool exists but its schema is not loaded,
and a direct call fails with `InputValidationError` (or a "schema not loaded" / "tool not
loaded" error) rather than `No such tool available`. That failure is NOT a capability
refutation. When any team primitive fails this way:

1. Call `ToolSearch("select:<ToolName>")` (e.g. `ToolSearch("select:SendMessage,TaskCreate,TaskUpdate,TaskList,TaskGet")`)
   to load the schema, then retry the op ONCE.
2. Only if `ToolSearch` reports no matching deferred tool (or the retry still throws
   `No such tool available`) does the failure count as a refutation for the guarded
   contract above.

Misreading a deferred tool as a missing tool is exactly the failure that silently downgrades
a teams-capable harness to the no-teams fallback — rescue first, refute second.

`teams_mode` and `teams_available` are persisted into `.loop-spec/runtime.json` together with
the workflow probe below; phase skills read them to pick their dispatch path.


Model availability is probed in Step 3.5. There is no preset axis; the probe
covers the complete effective selector set after phase and role overrides.

