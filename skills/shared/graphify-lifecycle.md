# Graphify assistant lifecycle

This is the single construction and refresh contract for Graphify inside loop-spec.
Cycle Step 5.4 and map-codebase Step 0 call it once per selected repository. Graph
construction is assistant-owned so semantic extraction uses the host session's model
and authentication; shell code only checks the package and validates outputs. Graph
output is local navigation state during feature work, never delivery-PR content.

## Inputs

- `repo`: absolute path to one selected Git repository root.
- `required`: `LOOP_SPEC_REQUIRE_GRAPHIFY` semantics; default is required.

Run repositories sequentially. Graphify writes shared intermediates, so parallel builds
inside one repository are forbidden.

## Procedure

1. Capture loop-spec paths before loading the external skill. Loading another skill
   changes `CLAUDE_SKILL_DIR` under pi and OpenCode.

   ```bash
   loop_spec_skill_dir="${CLAUDE_SKILL_DIR}"
   graphify_lib="${loop_spec_skill_dir}/../../lib/graphify-preflight.sh"
   harness="$(bash "${loop_spec_skill_dir}/../../lib/harness.sh" detect)"
   ```

2. Check the Graphify package with `bash "$graphify_lib" check`. The graph serves the
   **ripple layer** — hotspots, god nodes, cross-module reach — and nothing else
   substitutes for it. It is not the gate for the whole run: structural lookups have
   other answers, so an absent graph degrades one layer and the cycle continues.

   ```text
   exit 0, graphify present    build/refresh as below
   exit 0, graphify absent     ripple layer unavailable; log it, skip invocation and
                               staging, and let the design phases proceed on the
                               structural layer (bash lib/code-graph.sh layers)
   exit 1                      operator set LOOP_SPEC_REQUIRE_GRAPHIFY=1 and meant it
                               — fatal
   ```

   When the ripple layer is unavailable, SPEC and DISCUSS lose the "which subsystems
   will this ripple through" input. Say so in the phase report rather than
   substituting a guess: a boundary question the graph would have sharpened is one
   the human should be asked instead.

3. Ask the deterministic freshness helper before selecting assistant arguments:

   ```text
   freshness = bash "$graphify_lib" freshness "$repo"
   fresh:                    validate + localize only; do NOT invoke Graphify
   stale/missing/invalid:    invoke Graphify ("." for a missing graph,
                             ". --update" for a usable but stale graph)
   ```

   A `fresh` verdict is strict: complete output validation plus an ignored provenance
   stamp whose SHA-256 covers every tracked input except runtime state and Graphify's
   own output. Changed code, docs, papers, images, mode bits, renamed paths, a dirty
   tree, a missing stamp, or a malformed stamp all return `stale`. The first form runs
   Graphify's complete assistant build. The second runs its incremental assistant
   update: code changes use local AST extraction, while changed docs, papers, images,
   and other semantic inputs use the current host model. Never substitute the AST-only
   terminal command `graphify update .`.

4. Treat `repo` as Graphify's effective working directory. The argument remains `.`;
   every Bash/Python action prescribed by Graphify must execute from `repo`, and every
   output must land under `$repo/graphify-out/`. This is mandatory in workspace mode,
   where the session root itself is not a repository.

5. Invoke the unnamespaced external Graphify skill on the primary thread:

   **Claude Code**

   ```text
   Skill({skill: "graphify", args: arguments})
   ```

   **OpenCode**

   ```text
   skill({name: "graphify"})
   ```

   The OpenCode skill tool has no argument field. After loading it, execute the loaded
   workflow with `arguments` from Step 3 and the effective working directory from Step
   4. Translate Graphify semantic `Agent`/`@agent` fan-out into native
   `task({description, prompt, subagent_type: "general"})` calls from the primary
   session. If that generic dispatch is unavailable, process the same chunks inline;
   do not silently omit semantic inputs.

   **pi**

   Read the `SKILL.md` belonging to pi's discovered external `graphify` skill, then
   follow it with `arguments` from Step 3 and the effective working directory from
   Step 4. It is external, not a sibling under loop-spec's `skills/`. Because pi has
   no subagents, apply `skills/shared/pi-harness.md` and process Graphify's semantic
   chunks sequentially inline with the current host model.

6. Embedded mode overrides Graphify's standalone conversational ending. Use the entire
   selected repository when Graphify would ask to narrow a large corpus; never ask a follow-up question after the graph is built, and do not offer to trace a suggested
   query. Autonomous and interactive loop-spec runs follow the same rule because the
   cycle owns all user interaction.

7. On a `stale` verdict, the assistant invocation must return successfully. "Nothing to
   update" is success; a missing skill, extraction error, skipped semantic chunk, shrink
   refusal, or other failed/incomplete result is failure. Do not accept an older valid
   graph as proof that this invocation succeeded. A `fresh` verdict is the only allowed
   reuse proof. When required, fail with the harness-specific registration hint. Under
   `LOOP_SPEC_REQUIRE_GRAPHIFY=0`, warn and use the degraded Glob/Grep path.

8. Restore loop-spec's captured skill path, then validate and keep the generated graph
   local to this checkout. After a successful assistant build/update, write the matching
   local provenance stamp. Reused graphs are revalidated but not restamped.

   ```bash
   export CLAUDE_SKILL_DIR="$loop_spec_skill_dir"
   bash "$graphify_lib" validate "$repo"
   bash "$graphify_lib" localize "$repo"
   [[ "$freshness" == "fresh" ]] || bash "$graphify_lib" stamp "$repo"
   ```

   Validation requires named, non-opaque nodes and the complete shared output set:
   `graph.json`, `GRAPH_REPORT.md`, `manifest.json`, and `graph.html`.

9. **Do not stage or commit `graphify-out/` on a feature branch.** A semantic update
   can legitimately regenerate most of `graph.json`, `manifest.json`, and report
   artifacts after a small source change; including that derived churn in a feature PR
   obscures the actual implementation. `localize` adds the directory to the clone-local
   ignore policy, de-stages any previously staged graph paths, and protects historical
   tracked outputs from accidental feature commits. The graph remains available to this
   run's mappers and queries.

   After the feature merges, refresh Graphify from the default branch or a dedicated
   graph-maintenance checkout and review/publish that generated-data change separately:

   ```bash
   bash "$graphify_lib" publish "$repo"
   git -C "$repo" diff --cached -- graphify-out/
   # after reviewing the generated-data diff:
   git -C "$repo" commit -m "chore: refresh graphify knowledge graph"
   ```

   `publish` is an explicit maintenance operation: it reverses localize's
   skip-worktree protection and stages only portable output, leaving caches and host
   files out. A feature delivery must never be held hostage by a graph refresh or made
   unreviewable by it.

## Installation Failure

The binary check cannot prove assistant-skill discovery. If Step 5 cannot load
`graphify`, fail with the matching command:

```text
Claude Code: graphify install
pi:          graphify install --platform pi
OpenCode:    graphify install --platform opencode
```

Restart the harness after registration so its skill registry is refreshed.
