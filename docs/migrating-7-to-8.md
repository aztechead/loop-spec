# Migrating from loop-spec 7.x to 8.0

For someone who runs loop-spec 7.x in Claude Code or on the Agent SDK and is moving to
8.0, or deciding to stay on 7.x. It lists what changed for you and what to do.

## What changed

| 7.x | 8.0 |
|---|---|
| Six program-checked phases (SPEC, PLAN, EXECUTE, VERIFY, ITERATE, DELIVER), each with postconditions | Five steps written as guidance in one skill; ITERATE's whole-change judgment is the reviewer pass before verify |
| The program issued every step (`LOOP_SPEC_NEXT`), and the lead submitted each one | The lead drives the run; `status`, `task start`, and `task done` name the next step |
| Role skills (`roles/<name>/`) with schemas and attested dispatch | Two plugin agents: `loop-spec:implementer` (Sonnet) and `loop-spec:reviewer` (Opus) |
| Entries `auto`, `spec`, `plan`, `execute`, `verify`, `iterate`, `deliver` | Removed. Use `cycle`, `micro`, `debug`, `revise`, `status`; any run resumes from `status` |
| `--answer-policy default`, `spec.approval: policy` | `--autonomous`, or `LOOP_SPEC_MODE=autonomous` in the environment: the run never asks, and records the defaults it chose as assumptions |
| State under `~/.loop-spec/` (`LOOP_SPEC_HOME`) | State under `<repo>/.loop-spec/runs/<slug>/` |
| Result: `<state home>/<repo id>/<slug>/result.json`, schema 1, and `last-result.json` | Result: `<repo>/.loop-spec/runs/<slug>/result.json` and a `LOOP_SPEC_RESULT {...}` line; no `last-result.json` |
| `roles.*`, `phases.*`, `evidence.*`, `deliver.after`, `deliver.readiness`, `deliver.acceptRemotePaths`, `LOOP_SPEC_MODEL_*`, `LOOP_SPEC_EFFORT_*` | Removed. Customize with your repository's `CLAUDE.md` and skills; models are in the agents' frontmatter |
| `deliver.base`, `deliver.branch`, `deliver.branchPrefix`, `deliver.reviewers`, `deliver.labels` | The same keys at the top level of `.loop-spec/config.json`: `base`, `branch`, `branchPrefix`, `reviewers`, `labels` |
| Commands ran without a shell, with a syntax check | Checks run with `bash -c` from the repository root |
| `examples/supervisor/` and `loop_spec.sdk_runner` | Removed. `examples/sdk-plugin/` remains |

## Moving

1. Finish or abandon any 7.x run first. 8.0 does not read 7.x state.
2. Update the plugin (`/plugin marketplace update loop-spec-marketplace`).
3. Move `deliver.*` keys in `.loop-spec/config.json` to the top level as above, and
   drop the rest.
4. An Agent SDK host: replace `--answer-policy default` (or the example's `--auto`)
   with `LOOP_SPEC_MODE=autonomous` in `ClaudeAgentOptions(env=...)`, and read the result from the
   `LOOP_SPEC_RESULT` line or `result.json`'s `status`, `summary`, `prUrl`, and
   `verifiedSha`.

## Staying on 7.x

7.9.0 is the last 7.x release, at commit `85b42ee`. Pin the marketplace to a ref that
holds it (a `7.x` branch, once the maintainer creates one there, the way `6.x` was):

```
/plugin marketplace remove loop-spec-marketplace
/plugin marketplace add aztechead/loop-spec#7.x
/plugin install loop-spec@loop-spec-marketplace
```
