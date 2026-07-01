# Cycle Step 4 -- Detect project commands (reference)

Extracted verbatim from `skills/cycle/SKILL.md`; the SKILL stub points here. Apply as written.

### Step 4 - Detect project commands

**Single-repo mode (unchanged):**

Auto-detect (best effort):
- test: parse package.json scripts.test, Makefile `test` target, pyproject.toml [tool.pytest], go.mod presence (`go test ./...`)
- lint: scripts.lint, Makefile lint, ruff/eslint config files
- typecheck: scripts.typecheck, mypy.ini, tsconfig.json + tsc

**Prefer direct binaries over package-manager wrappers (node projects).** When the project
is a node project (`package.json` present) and `node_modules/.bin/` exists, emit the direct
binary form rather than `npx`/`npm run`: `node_modules/.bin/vitest run`, `node_modules/.bin/tsc --noEmit`,
`node_modules/.bin/eslint .` — NOT `npx vitest` / `npm run typecheck`. The wrappers are
sensitive to shell shims: under nvm (and the RTK+nvm interaction) `node`/`npm`/`npx` may
resolve to a shell function that prints help instead of executing non-interactively, which
would make every generated verify command fail as written. `node_modules/.bin/*` invokes the
binary directly and sidesteps the shim. (If a script is genuinely only reachable via
`npm run <name>`, keep it but note the dependency on a working `npm` in the shell.)

**Probe that the detected commands actually execute** via `lib/resolve-bin.sh`, which
resolves the REAL on-disk executable past shell-function shims (nvm/pyenv/rbenv/asdf) and
prefers `node_modules/.bin/*`. This is the general form of the node/nvm fix — it works for
python/ruby version managers too. Surface a clear error rather than letting every later
verify silently fail:

```bash
# For each detected runner the commands depend on (node, npx, python, etc.), confirm a
# real binary resolves; if it does, prefer that absolute path in the generated command.
for tool in node npx python python3; do
  case "$cmd_test$cmd_lint$cmd_typecheck" in
    *"$tool"*)
      if ! bash "${CLAUDE_SKILL_DIR}/../../lib/resolve-bin.sh" "$tool" . >/dev/null 2>&1; then
        echo "loop-spec: '$tool' does not resolve to a real executable in this shell" >&2
        echo "  (likely a version-manager shell-function shim). Generated verify commands" >&2
        echo "  may fail. Prefer node_modules/.bin/* (auto), or put the real binary on PATH." >&2
      fi ;;
  esac
done
```

Confirm with user via AskUserQuestion (one Q with options):
- "Detected commands: test=`{X}`, lint=`{Y}`, typecheck=`{Z}`. Use these?"
- Options: "Yes", "Customize"

If customize: ask each separately.

Skip this confirmation step when `LOOP_SPEC_NON_INTERACTIVE=1` (use auto-detected values as-is).

Normalize all three to strings so `feature.commands` always carries `test`/`lint`/`typecheck` keys (undetected = empty string, never null; phases treat empty as "skip this check"): `cmd_test="${cmd_test:-}"; cmd_lint="${cmd_lint:-}"; cmd_typecheck="${cmd_typecheck:-}"`.

**Workspace mode (additive):**

Run the same auto-detection per participating repo using the repo's absolute path as the probe dir. Collect per-repo command maps:

```bash
declare -A repo_cmds_test repo_cmds_lint repo_cmds_typecheck
for repo_entry in $(echo "$workspace_repos_json" | jq -c '.[]'); do
  rname="$(echo "$repo_entry" | jq -r '.name')"
  rpath="${workspace_root}/$(echo "$repo_entry" | jq -r '.path')"
  # run same detection logic against "$rpath"
  repo_cmds_test["$rname"]="${detected_test:-}"
  repo_cmds_lint["$rname"]="${detected_lint:-}"
  repo_cmds_typecheck["$rname"]="${detected_typecheck:-}"
done
```

Present a single AskUserQuestion listing all repos and detected commands; user confirms or customizes per-repo. Skip when `LOOP_SPEC_NON_INTERACTIVE=1`. Top-level `commands` in feature.json will carry empty strings (workspace mode per-repo commands are authoritative in `workspace.repos[].commands`).
