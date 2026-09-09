# Headless session layer

For the integrator who runs loop-spec unattended (`claude -p`, `codex exec`,
`opencode run`) and wants to know what EXECUTE's `session` rung launches, and for the
maintainer who adds a profile. The rung itself, and when the ladder selects it, is in
`skills/shared/execute-rungs.md` ("Disposable session"); the probe is
`bash lib/harness.sh session-layer`.

## What it does

`session_run.py` runs one agent node as its own headless CLI process: one profile, one
working directory, one prompt file, one JSON result line. The process exit is the
completion signal. There is no hook relay because print mode has no terminal to observe.

```bash
python3 extensions/sessions/session_run.py --profile claude --cwd "$worktree" \
  --prompt-file "$prompt" --model "$model" --seed-from "$featureRoot" \
  --log-dir "$featureDir/dispatch/sessions"
```

`--bypass` swaps the profile's guarded arguments for its bypass arguments. Claude Code
refuses bypassPermissions under root, so the Claude profile's guarded line grants the
implementer's tools outright instead.

The result line:

```json
{"status": "completed", "exit": 0, "argv": ["claude", "-p", "..."], "stdout": "...", "stderr": "...", "durationSeconds": 41.2, "envFault": null}
```

| exit | status | meaning |
|---|---|---|
| 0 | `completed` | the CLI exited 0 |
| 1 | `failed` | the CLI exited non-zero for a reason the profile does not name |
| 2 | | bad call, or the profile is missing or malformed |
| 3 | | the CLI binary is not on PATH, or `python3` is older than 3.11 |
| 4 | `env-fault` | the CLI failed on a provider or transport line the profile names; retry, do not charge the attempt |
| 5 | `timeout` | `--timeout` (else `LOOP_SPEC_SESSION_TIMEOUT_SECS`, else 3600) elapsed; the process was killed |

The child inherits the environment minus every `LOOP_SPEC_*` name, the harness's
plugin bindings (`CLAUDE_PROJECT_DIR`, `CLAUDE_SKILL_DIR`, `CLAUDE_PLUGIN_ROOT`), and
`CLAUDE_CODE_SESSION_ID`: the session is an implementer, not a member of the cycle that
dispatched it, and it writes its own transcript.

## Profiles

One TOML file per harness CLI under `profiles/`, named as `lib/harness.sh cli` answers.
`LOOP_SPEC_SESSION_PROFILES=<dir>` is searched first, so a project can copy a profile
and edit it without touching the plugin. The keys the runner reads:

| key | meaning |
|---|---|
| `binary` | the executable; must be on PATH |
| `launch_args` | arguments that put the CLI in headless mode, in order |
| `guarded_args` | arguments added without `--bypass` (the CLI's own permission gate) |
| `bypass_args` | arguments added with `--bypass` instead of `guarded_args` |
| `model_flag` | the flag before `--model`'s value; omitted when the model is `inherit` |
| `prompt_template` | the prompt argument; `{prompt}` is the prompt file's text; always last |
| `seed_files` | gitignored paths copied from `--seed-from` into `--cwd` when absent there |
| `env_fault_patterns` | regexes matched line by line against the last 64 KiB of output when the CLI fails; a match is `env-fault` |
| `[env]` | variables set in the child |

The shape and the shipped fault patterns are vendored (see `NOTICE`). Every pattern is a
line a CLI printed in a captured run, never a plausible one: the session's log carries
the model's own output, and a task that writes about an API error must not read as an
outage. Runtime for this directory is Python 3.11 (`tomllib`) with no third-party
imports; the base runtime floor in `CLAUDE.md` does not move.

`tests/sessions-extension.test.sh` pins the argument order, the environment, the
seeding, the fault classification, and that no shipped pattern matches its own profile.
