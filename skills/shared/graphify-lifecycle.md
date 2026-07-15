# Graphify assistant lifecycle

This is the single construction and refresh contract for Graphify inside loop-spec.
Cycle Step 5.4 and map-codebase Step 0 call it once per selected repository. Graph
construction is assistant-owned so semantic extraction uses the host session's model
and authentication; shell code only checks the package, validates outputs, and stages
the portable artifacts.

## Inputs

- `repo`: absolute path to one selected Git repository root.
- `commit_message`: graph-only commit message chosen by the caller.
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

2. Check the Graphify package with `bash "$graphify_lib" check`. If the binary is
   absent and `LOOP_SPEC_REQUIRE_GRAPHIFY=0`, log the degraded Glob/Grep fallback and
   return without invoking or staging. Otherwise failure is fatal.

3. Select assistant arguments from the validated prior state:

   ```text
   missing or invalid graph: arguments = "."
   usable existing graph:    arguments = ". --update"
   ```

   The first form runs Graphify's complete assistant build. The second runs its
   incremental assistant update: code changes use local AST extraction, while changed
   docs, papers, images, and other semantic inputs use the current host model. Never
   substitute the AST-only terminal command `graphify update .`.

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

7. The assistant invocation must return successfully. "Nothing to update" is success;
   a missing skill, extraction error, skipped semantic chunk, shrink refusal, or other
   failed/incomplete result is failure. Do not accept an older valid graph as proof that
   this invocation succeeded. When required, fail with the harness-specific registration
   hint. Under `LOOP_SPEC_REQUIRE_GRAPHIFY=0`, warn and use the degraded Glob/Grep path.

8. Restore loop-spec's captured skill path, then validate and stage:

   ```bash
   export CLAUDE_SKILL_DIR="$loop_spec_skill_dir"
   bash "$graphify_lib" validate "$repo"
   bash "$graphify_lib" stage "$repo"
   ```

   Validation requires named, non-opaque nodes and the complete shared output set:
   `graph.json`, `GRAPH_REPORT.md`, `manifest.json`, and `graph.html`.

9. Commit only staged Graphify outputs when they changed:

   ```bash
   if ! git -C "$repo" diff --cached --quiet -- . ':(exclude)graphify-out/**'; then
     echo "loop-spec: unexpected staged path outside graphify-out; refusing graph commit" >&2
     exit 1  # Do not sweep another phase's staged work.
   fi
   if ! git -C "$repo" diff --cached --quiet -- graphify-out/; then
     git -C "$repo" commit -m "$commit_message"
   fi
   ```

   The first guard must abort rather than continue when it prints the error. Committing
   the prepared index, without a pathspec, preserves staged removals of previously tracked
   local artifacts. The staging helper excludes machine paths, cost history, caches, dated
   backups, locks, and partial assistant intermediates. Never replace it with blanket
   `git add` or a pathspec commit.

## Installation Failure

The binary check cannot prove assistant-skill discovery. If Step 5 cannot load
`graphify`, fail with the matching command:

```text
Claude Code: graphify install
pi:          graphify install --platform pi
OpenCode:    graphify install --platform opencode
```

Restart the harness after registration so its skill registry is refreshed.
