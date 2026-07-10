# Live e2e smoke tests

`run-e2e.sh` runs ONE full autonomous cycle against a throwaway fixture repo and
asserts the machine-readable headless contract (`result.json` schema 1 +
`events.jsonl`). It is the scripted counterpart to the manual matrix in
`tests/README.md`.

`run-e2e-sentinel.sh` is the sentinel-scenario sibling (ROADMAP-3.0 A3+A4):
it seeds a backlog entry in the fixture, runs `claude -p "/loop-spec:sentinel
run"`, and asserts the drive loop scanned, recorded the pick in
`.loop-spec/sentinel-events.jsonl`, drove a cycle to a valid terminal status
on a `feat/*` branch, and never advanced `main` (PR-terminated — no
auto-merge at any trust level). Same prerequisites and flags as `run-e2e.sh`;
`tests/run-all.sh --e2e` runs both.

**It is opt-in and it is not free**: a real `claude -p` autonomous cycle,
typically 10–45 minutes of wall clock and the token cost of a small feature.
It is never part of the default offline suite.

## Run

```bash
bash tests/e2e/run-e2e.sh          # directly
bash tests/run-all.sh --e2e        # offline suite first, then this
```

Prerequisites: `claude` (logged in), `git`, `jq` on PATH. Missing prereqs exit 2
(assertion failures exit 1) so CI can distinguish "can't run" from "broken".

## What it does

1. Creates a tmp fixture repo (`calc.sh` with an `add` function + a test script),
   no origin remote — push/PR/checkpoint paths must degrade gracefully.
2. Installs THIS checkout of the plugin into the fixture with
   `claude plugin marketplace add <repo> --scope local` + `claude plugin install
   --scope local`. Local scope lives in the fixture's `.claude/settings.local.json`;
   your user-level Claude config is never touched. (An isolated
   `CLAUDE_CONFIG_DIR` was probed and rejected: the CLI loses OAuth credentials
   outside the default config dir.)
3. Runs `claude -p "/loop-spec:cycle autonomous <add a subtract function>"` with
   `LOOP_SPEC_REQUIRE_GRAPHIFY=0 LOOP_SPEC_SKIP_HEALTHCHECK=1
   LOOP_SPEC_CHECKPOINT_PR=0` under a portable wall-clock watchdog.
4. Asserts: `last-result.json` exists, schema 1, valid terminal status, non-empty
   slug, boolean `converged`; `events.jsonl` parses, has a `phase_start`, and its
   terminal event matches the result status; a `feat/*` branch exists; and on
   `status == completed` the subtract function is actually in the tree.

## Flags

| Env | Effect |
|---|---|
| `LOOP_SPEC_E2E_TIMEOUT_MINS` | Wall-clock ceiling (default 45). |
| `LOOP_SPEC_E2E_KEEP=1` | Keep the tmp workdir for inspection. |
| `LOOP_SPEC_E2E_PERMISSION_FLAGS` | Override permission flags passed to `claude -p`. Default `--dangerously-skip-permissions` — acceptable only because the run is confined to a throwaway fixture repo with no remote. |
