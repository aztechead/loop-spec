# Phase loop — reacting to a phase skill's return (cycle Step 6, items 2-3)

Read when the cycle reaches Step 6 and a phase skill has just returned (or is about
to be re-invoked in the same session). The skill body keeps item 1 (activate the
model map, `cycle-result.sh begin`, extension points, `Skill(...)` dispatch); this
file owns everything between that return and the next dispatch. Item numbering
continues from the skill body.

Contents: item 2 — re-load feature.json, declined-SPEC terminal, phase watchdog,
PROGRESS.md journaling, state commit, autonomous remote checkpoint · item 3 — route to
the next iteration via the graph engine.

2. **Re-load feature.json** after the skill returns (the skill may have advanced `currentPhase` and updated artifacts):
   ```bash
   feature_json=$(cat ".loop-spec/features/${slug}/feature.json")
   next_phase=$(echo "$feature_json" | jq -r '.currentPhase')
   if [[ "$currentPhase" == "deliver" \
         && -f ".loop-spec/features/${slug}/delivery.json" ]]; then
     next_phase="$(jq -r '.nextPhase // "deliver"' \
       ".loop-spec/features/${slug}/delivery.json")"
   fi
   phase_result=".loop-spec/features/${slug}/result.json"
   if [[ -f "$phase_result" \
         && "$(jq -r '.status // empty' "$phase_result")" == "paused" ]]; then
     pause_reason="$(jq -r '.reason // empty' "$phase_result")"
     case "$pause_reason" in
       spec-confirmation-declined|spec-override-declined)
         cat "$phase_result"
         echo "loop-spec: declined SPEC gate is terminal for this invocation." >&2
         exit 0
         ;;
     esac
   fi
   ```

   A declined SPEC gate ends the phase loop: surface the printed `result.json` to the
   caller and do NOT route to another phase. (`exit 0`, not `return` — these blocks run
   as standalone Bash invocations, where `return` is a shell error rather than a
   control-flow instruction.)

   **Phase watchdog check:** resolve the ceiling once before comparison and reject an
   invalid value:
   ```bash
   phase_timeout_mins="${LOOP_SPEC_PHASE_TIMEOUT_MINS:-60}"
   [[ "$phase_timeout_mins" =~ ^[1-9][0-9]*$ ]] || {
     echo "loop-spec: LOOP_SPEC_PHASE_TIMEOUT_MINS must be a positive integer" >&2
     exit 2
   }
   ```
   Compare now against `currentPhaseStartedAt` and `phase_timeout_mins`. If the phase
   that just returned exceeded its ceiling, print a one-line warning
   (`phase {name} took {N}m, ceiling {M}m`) and append it to `warnings[]`; if a RESUMED
   feature's `currentPhaseStartedAt` is already past the ceiling before re-invoking
   (the previous session hung or died mid-phase), do NOT blindly re-enter — surface it:
   `phase {name} exceeded its {M}m ceiling in a prior session; resuming from last durable
   state` and let the phase skill's own resume logic pick up from artifacts. The
   watchdog never kills work; it makes a wedged loop visible instead of silently eternal.

   Refresh `updatedAt` through `feature-write.sh` on every durable transition so a long
   phase sequence remains resumable past the staleness window.
   ```bash
   if [[ "$currentPhase" != "deliver" || "$next_phase" == "execute" ]]; then
     bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" set \
       ".loop-spec/features/${slug}" updatedAt "\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
   fi
   ```

   **DELIVER external-observation exception:** when the phase that returned was
   `deliver` and `next_phase` is `completed` or `deliver`, skip the
   tracked timestamp/progress/state commit below. The engine emits `phase_end` on
   the following `--step`. Success proved the exact PR head SHA;
   a hard transport/identity/timeout failure also binds its retry to the exact attempted
   SHA. Any new commit would invalidate either invariant. Only `next_phase == "execute"`
   mutates and commits tracked remediation state.

   **Progress journal (append-only narrative — the machine state's "why").** For every
   other transition, append one short block to `.loop-spec/features/{slug}/PROGRESS.md`
   (create with a `# Progress — {slug}` heading if absent):
   ```
   ## {ISO timestamp} — {phase} → {next_phase}
   - did: <1-2 lines: what this phase produced/decided>
   - next: <1 line: what the next phase must do>
   - gotchas: <0-2 lines: anything a fresh session must know (build quirks, env, partial work); omit if none>
   ```
   Commit it together with feature.json below — and ensure the gitignore exception exists first (the feature dir is ignored except named files; without this line the add silently no-ops):
   ```bash
    if [[ "$workspaceMode" != "workspace" ]]; then
      if ! bash "${CLAUDE_SKILL_DIR}/../../lib/owned-gitignore.sh" check .; then
        echo "cycle: refusing to mix pre-existing .gitignore changes with loop-spec policy" >&2
        exit 2
      fi
      grep -qxF '!/.loop-spec/features/*/PROGRESS.md' .gitignore 2>/dev/null \
        || printf '!/.loop-spec/features/*/PROGRESS.md\n' >> .gitignore
      grep -qxF '!/.loop-spec/RULES.md' .gitignore 2>/dev/null \
        || printf '!/.loop-spec/RULES.md\n' >> .gitignore
    fi
   ```
   (The RULES.md exception makes self-learning rules durable in volatile
   workspaces — a rule written in a per-run container survives via git instead
   of dying with the pod. Commit RULES.md whenever the loop adds a rule.)
   `events.jsonl` and `result.json` are local telemetry, deliberately not committed — the default `.loop-spec/features/*/` gitignore covers them and no exception is added.

   feature.json says WHERE the loop is; PROGRESS.md says WHY — it is what a fresh or compacted session reads to re-orient (Step 1 re-grounding), and the handoff document for fresh-context rewinds.

   Do not emit `phase_end` here. The next Step 5.9 `--step` closes this phase
   when it leaves the node, even if the agent ran the work inline and never
   invoked the phase skill.

   **Commit the resume contract (single point).** Resolve the state commit policy with
   `bash "${CLAUDE_SKILL_DIR}/../../lib/state-commit-policy.sh" mode`. The default
   `phase` mode commits feature.json at every boundary so clone-based resume remains
   available. `LOOP_SPEC_SQUASH_STATE_COMMITS=1` returns `final`: leave feature.json
   and PROGRESS.md in the working tree and let DELIVER create one final state commit.
   Final mode intentionally disables remote phase checkpoints because their pushed
   state would require a history rewrite later.

   In `phase` mode, feature.json is committed (not gitignored)
   so resume survives a clone or hand-off to another machine. The cycle is the one place
   that observes every phase transition, so it snapshots state here -- phase skills do NOT
   each commit feature.json. Guarded so workspace-mode (where the root may not be a git
   repo) is a safe no-op:
   ```bash
   fj=".loop-spec/features/${slug}/feature.json"
    state_commit_mode="$(bash "${CLAUDE_SKILL_DIR}/../../lib/state-commit-policy.sh" mode)"
    if [[ "$state_commit_mode" == "phase" && "$workspaceMode" != "workspace" ]] \
       && [[ "$currentPhase" != "deliver" || "$next_phase" == "execute" ]] \
      && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      state_paths=("$fj" ".loop-spec/features/${slug}/PROGRESS.md" ".gitignore")
      git add -- "${state_paths[@]}" 2>/dev/null
      git diff --cached --quiet -- "${state_paths[@]}" 2>/dev/null \
        || git commit -q -m "chore: NO_JIRA ${slug} state @ ${next_phase}" -- \
          "${state_paths[@]}" || true
   fi
   ```

   **Autonomous remote checkpoint:** after the state commit and before routing onward,
   push the current branch and create/reuse its draft PR. This runs at every non-DELIVER
   phase boundary so a container death loses at most the current uncommitted phase. It is
   default-on only for autonomous single-repository runs; set
   `LOOP_SPEC_CHECKPOINT_EACH_PHASE=0` to disable.

   ```bash
   feature_autonomous="$(jq -r '.autonomous // false' \
     ".loop-spec/features/${slug}/feature.json")"
   checkpoint_default=0
   [[ "$feature_autonomous" == "true" ]] && checkpoint_default=1
   checkpoint_each="${LOOP_SPEC_CHECKPOINT_EACH_PHASE:-$checkpoint_default}"
   case "$checkpoint_each" in
     0|1) ;;
     *) echo "loop-spec: LOOP_SPEC_CHECKPOINT_EACH_PHASE must be 0 or 1" >&2; exit 2 ;;
   esac
   if [[ "$state_commit_mode" == "phase" && "$workspaceMode" != "workspace" && "$currentPhase" != "deliver" \
         && "$checkpoint_each" == "1" ]]; then
     bash "${CLAUDE_SKILL_DIR}/../../lib/checkpoint-pr.sh" create \
       ".loop-spec/features/${slug}" --reason "autonomous phase checkpoint: ${next_phase}"
   fi
   ```

3. **Route to next iteration:**
   - If `next_phase == "completed"`: jump to the "On completion" section below.
    - If the phase that returned was `deliver`, `next_phase == "deliver"`, and
      `delivery.nextPhase == "deliver"`, branch on the deterministic delivery record.
      When `delivery.status == "no-changes"`, every target is `no_commits` or
      `skipped-no-commits`, and the last ITERATE verdict has both `converged == true`
      and `deterministic_gate_passed == true` with no unresolved iteration warnings,
      pass `--status completed`, the verdict's non-empty `.summary`, and
      `--no-change-reason already-satisfied`; the writer normalizes the output to
      `outcome: no-change-needed` and re-validates all three facts. Use this exact probe:
      ```bash
      feature_dir=".loop-spec/features/${slug}"
      delivery_file="$feature_dir/delivery.json"
      if jq -e '.status == "no-changes" and ((.targets // []) | length > 0) and
          ((.targets // []) | all(.errorCode == "no_commits" or .outcome == "skipped-no-commits"))' \
          "$delivery_file" >/dev/null 2>&1 \
        && jq -e '.iterate.lastVerdict.converged == true and
          .iterate.lastVerdict.deterministic_gate_passed == true and
          ((.warnings // []) | map(type == "string" and
            (startswith("iterate-budget-spent:") or startswith("iterate-terminal:"))) |
            any | not) and
          ((.iterate.lastVerdict.summary // "") | test("\\S"))' \
          "$feature_dir/feature.json" >/dev/null 2>&1; then
        _summary="$(jq -r '.iterate.lastVerdict.summary' "$feature_dir/feature.json")"
        bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-result.sh" write "$feature_dir" \
          --status completed --summary "$_summary" \
          --no-change-reason already-satisfied
      else
        _reason="$(jq -r '(.status // "unknown") as $status |
          ([.targets[]?.error // empty] | first //
            ("delivery stopped with status " + $status))' "$delivery_file")"
        bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-result.sh" write "$feature_dir" \
          --status escalated --reason "$_reason" --summary "Delivery stopped: $_reason"
      fi
      ```
      **No-change completion cleanup:** after the `already-satisfied` result is emitted,
      print its summary and do not run PR feedback or autonomous chaining. For a Claude
      single-repository feature worktree, call `ExitWorktree({action:"keep"})` before
      returning; OpenCode/ADK in-place execution and workspace mode skip that tool. This
      is the terminal cleanup for this path, so it must happen before preflight begins
      suppressing the completed local result on later invocations.
      Eligible immutable targets normalize to `delivery-blocked`; local preflight errors
      remain escalations. Return control. Never immediately invoke DELIVER again;
     transport/identity/timeouts need an external condition to change.
   - **Fresh phase orchestrator (opt-in):** when
     `feature.json.phaseHandoff == true`, `next_phase != currentPhase`, and the run is
     not already routing to terminal completion, write a paused machine result before
     returning:
     ```bash
     feature_dir=".loop-spec/features/${slug}"
     summary="Phase ${currentPhase} completed; ${next_phase} is ready in durable state."
     bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-result.sh" write "$feature_dir" \
       --status paused --reason phase-handoff --summary "$summary"
     next_model="$(bash "${CLAUDE_SKILL_DIR}/../../lib/feature-init.sh" \
       phase-model "$next_phase")"
     printf 'LOOP_SPEC_PHASE_HANDOFF {"slug":"%s","completed":"%s","next":"%s","model":"%s"}\n' \
       "$slug" "$currentPhase" "$next_phase" "${next_model:-inherit}"
     ```
     The result clears `active-run.json`, so the current invocation is terminal from
     the container's perspective even though the feature is resumable. Re-running
     `/loop-spec:cycle phase:fresh` (or the original autonomous command with
     `LOOP_SPEC_PHASE_HANDOFF=1`) selects the latest resumable feature and enters
     `next_phase` with a fresh main-agent context. A supervisor may repeat until
     `last-result.json` is not `status=paused, reason=phase-handoff`.
   - **Fresh-context rewind (opt-in, `LOOP_SPEC_ITERATE_FRESH=1`):** only when the phase
     that returned was `iterate` and `next_phase` matches the explicit rewind set
     `execute|plan|spec|discuss`. `deliver` is forward progress and MUST run in the same
     context. If enabled for a rewind, commit the handoff and return with:
     `fresh-context rewind: state committed; relaunch with /loop-spec:cycle (or let your outer loop do it) to re-enter {next_phase} in a clean session.`
     and return to the user. An outer `while :; do claude -p "/loop-spec:cycle"; done` (or the loop-runner) drives the relaunch; resume detection re-enters at `{next_phase}` with a fresh window.
   - Otherwise, re-run the Step 5.9 graph-resolution snippet verbatim (`run.sh --step`
     in a loop until an `agent` node, a pause, an abort, or the terminal node) to obtain
     the next `currentPhase`, then loop back to "1. Invoke phase skill" above with that
     value. This single mechanism now covers both `execStyle` families: `auto` and
     `review-only` resolve straight through to the next agent node and continue; `step`
     and `interactive` land on an admitted `human.*` node, and `run.sh --step` itself
     exits 4 (pause) there — the snippet's exit-4 branch prints the pause and returns to
     the user exactly as the old style-branch used to, except the pause point is now the
     graph's own declared admit condition (`lib/graph/probes/human-gate.sh`) instead of a
     second, independently-maintained `execStyle` check in this prose. User re-invokes
     `Skill(loop-spec:cycle)` to continue (resume detection in Step 1, and `run.sh --step`'s
     own pause-record resolution, pick up the in-progress state — sec 5).

