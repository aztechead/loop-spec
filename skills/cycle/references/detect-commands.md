# Cycle Step 4 -- Detect project commands (reference)

Extracted verbatim from `skills/cycle/SKILL.md`; the SKILL stub points here. Apply as written.

### Step 4 - Detect project commands

**Single-repo mode (unchanged):**

Auto-detect (best effort):
- prepare: `LOOP_SPEC_CMD_PREPARE`, then `.loop-spec/workflow.json.prepareCommand`,
  then lock-aware npm/pnpm/yarn, uv/poetry, or isolated pip requirements setup through
  `lib/prepare-environment.sh resolve` — including workspace layouts where the lockfile
  sits below the root (a uv root with the frontend in `webapp/frontend/` resolves to
  `(cd webapp/frontend && npm ci) && uv sync --frozen`)
- test: parse package.json scripts.test, Makefile `test` target, pyproject.toml [tool.pytest], go.mod presence (`go test ./...`), project.clj (`lein test`), deps.edn (`clojure -M:test`), mix.exs (`mix test`), pom.xml (`mvn test`), build.gradle / build.gradle.kts (`gradle test`), Gemfile (`bundle exec rake test`), composer.json (`composer test`). Detection is marker-based and language-agnostic; it must not assume the project is JS or Python. `lib/detect-test-cmd.sh` is the probe.
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

**Never hand-roll a lockfile-mutating install.** Preparation runs under a "leaves the tree
unchanged" guard. `npm install`, `yarn add`, `pnpm install` without a frozen flag,
`poetry lock`, and `uv sync` without `--frozen` all rewrite the lockfile, so preparation
fails the guard and the lockfile has to be restored before the install is redone the
correct way. If the resolver returned no prepare command and dependencies genuinely must
be installed, emit the lock-preserving form: `npm ci`,
`pnpm install --frozen-lockfile`, `yarn install --immutable` (v1: `--frozen-lockfile`),
`uv sync --frozen`; for pip, install into an isolated `.venv` rather than the ambient
interpreter. For a lockfile in a subdirectory the resolver declined to pick (several
candidates, so it refused to guess), scope the same frozen form:
`(cd <subdir> && npm ci)`. This applies to feasibility probes too — probe with the frozen
install itself or something read-only (`npm --version`), never with a mutating install.

**Probe that the detected commands actually execute** via `lib/resolve-bin.sh`, which
resolves the REAL on-disk executable past shell-function shims (nvm/pyenv/rbenv/asdf) and
prefers `node_modules/.bin/*`. This is the general form of the node/nvm fix — it works for
python/ruby version managers too. Surface a clear error rather than letting every later
verify silently fail:

```bash
# For each detected runner the commands depend on (node, npx, python, etc.), confirm a
# real binary resolves; if it does, prefer that absolute path in the generated command.
for tool in node npm npx pnpm python python3; do
  case "$cmd_prepare$cmd_test$cmd_lint$cmd_typecheck" in
    *"$tool"*)
      if ! bash "${CLAUDE_SKILL_DIR}/../../lib/resolve-bin.sh" "$tool" . >/dev/null 2>&1; then
        echo "loop-spec: '$tool' does not resolve to a real executable in this shell" >&2
        echo "  (likely a version-manager shell-function shim). Generated verify commands" >&2
        echo "  may fail. Prefer node_modules/.bin/* (auto), or put the real binary on PATH." >&2
      fi ;;
  esac
done
```

Resolve preparation against the selected repository before confirmation:

```bash
prepare_resolution="$(bash "${CLAUDE_SKILL_DIR}/../../lib/prepare-environment.sh" resolve --root "$repo_root")"
cmd_prepare="$(jq -r '.command // ""' <<<"$prepare_resolution")"
```

Confirm with user via AskUserQuestion (one Q with options):
- "Detected commands: prepare=`{P}`, test=`{X}`, lint=`{Y}`, typecheck=`{Z}`. Use these?"
- Options: "Yes", "Customize"

If customize: ask each separately.

Skip this confirmation step when `LOOP_SPEC_NON_INTERACTIVE=1` (use auto-detected values as-is).

Normalize all four to strings so `feature.commands` always carries `prepare`/`test`/`lint`/`typecheck` keys (undetected = empty string, never null): `cmd_prepare="${cmd_prepare:-}"; cmd_test="${cmd_test:-}"; cmd_lint="${cmd_lint:-}"; cmd_typecheck="${cmd_typecheck:-}"`.

Then apply environment overrides through the deterministic resolver. Do not read or
reinterpret the variables independently in the skill:

```bash
resolved_commands="$(bash "${CLAUDE_SKILL_DIR}/../../lib/project-commands.sh" resolve \
  --prepare "$cmd_prepare" --test "$cmd_test" \
  --lint "$cmd_lint" --typecheck "$cmd_typecheck")"
cmd_prepare="$(jq -r '.prepare' <<<"$resolved_commands")"
cmd_test="$(jq -r '.test' <<<"$resolved_commands")"
cmd_lint="$(jq -r '.lint' <<<"$resolved_commands")"
cmd_typecheck="$(jq -r '.typecheck' <<<"$resolved_commands")"
```

Presence is authoritative, including an empty value. Thus
`LOOP_SPEC_CMD_PREPARE=""`, `LOOP_SPEC_CMD_TEST=""`, `LOOP_SPEC_CMD_LINT=""`, or
`LOOP_SPEC_CMD_TYPECHECK=""` explicitly disables that slot. Apply this before command
confirmation; non-interactive/autonomous paths skip confirmation but use the same
resolved values.

**Workspace mode (additive):**

Run the same auto-detection per participating repo using the repo's absolute path as the probe dir. Collect per-repo command maps:

```bash
declare -A repo_cmds_prepare repo_cmds_test repo_cmds_lint repo_cmds_typecheck
for repo_entry in $(echo "$workspace_repos_json" | jq -c '.[]'); do
  rname="$(echo "$repo_entry" | jq -r '.name')"
  rpath="${workspace_root}/$(echo "$repo_entry" | jq -r '.path')"
  # run same detection logic against "$rpath"
  repo_prepare="$(bash "${CLAUDE_SKILL_DIR}/../../lib/prepare-environment.sh" resolve --root "$rpath")"
  repo_cmds_prepare["$rname"]="$(jq -r '.command // ""' <<<"$repo_prepare")"
  repo_cmds_test["$rname"]="${detected_test:-}"
  repo_cmds_lint["$rname"]="${detected_lint:-}"
  repo_cmds_typecheck["$rname"]="${detected_typecheck:-}"
done
```

For each repository, pass those four detected values through
`lib/project-commands.sh resolve` exactly as in single-repo mode before storing them.
An environment override therefore applies consistently to every participating
repository. Present a single AskUserQuestion listing all repos and resolved commands;
the user confirms or customizes per-repo. Skip when `LOOP_SPEC_NON_INTERACTIVE=1`.
Top-level `commands` in feature.json will carry empty strings (workspace mode per-repo
commands are authoritative in `workspace.repos[].commands`).
