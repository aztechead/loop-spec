# Migrate from loop-spec 7.x to 8.0

For someone who runs loop-spec 7.x in Claude Code or through the Claude Agent SDK.
Follow these steps to move a repository to 8.0. Plan on about fifteen minutes.

> **Warning:** 8.0 ignores 7.x configuration keys without an error. If you set
> `deliver.base` and do not move it (step 3), 8.0 opens PRs against the default
> branch.

## Before you start

- Finish or abandon every 7.x run in the repository. 8.0 does not read 7.x run
  state, so an unfinished 7.x run cannot be resumed after the upgrade. Check with
  `/loop-spec:status` while 7.x is still installed.
- Decide whether to move now. 7.9.0 is the last 7.x release and gets hotfixes. To
  stay on it, see [Stay on 7.x](#stay-on-7x).

## 1. Update the plugin

```
/plugin marketplace update loop-spec-marketplace
```

Run `/plugin` and confirm loop-spec shows version 8.0.0.

## 2. Use the five entries

8.0 keeps five entries: `cycle`, `micro`, `debug`, `revise`, and `status`. Replace any
other entry you call in scripts, aliases, or docs:

| 7.x entry | 8.0 |
|---|---|
| `/loop-spec:auto` | `/loop-spec:cycle`, or just describe the change; Claude picks the entry |
| `/loop-spec:spec`, `plan`, `execute`, `verify`, `iterate`, `deliver` | `/loop-spec:cycle` for new work; any started run resumes from `/loop-spec:status` |

## 3. Update `.loop-spec/config.json`

Move the `deliver.*` keys you use to the top level, and delete the rest. For example:

```jsonc
// 7.x
{
  "deliver": {
    "base": "develop",
    "branchPrefix": "kv/",
    "reviewers": ["ana"],
    "after": ["my-plugin:pr-follow-up"],
    "readiness": "checks"
  },
  "spec": { "approval": "policy" },
  "roles": { "code-reviewer": { "model": "opus" } }
}

// 8.0
{
  "base": "develop",
  "branchPrefix": "kv/",
  "reviewers": ["ana"],
  "feedback": { "skills": ["my-plugin:pr-follow-up"] }
}
```

Use this table for each key:

| 7.x key | 8.0 |
|---|---|
| `deliver.base`, `deliver.branch`, `deliver.branchPrefix`, `deliver.reviewers`, `deliver.labels` | The same name at the top level: `base`, `branch`, `branchPrefix`, `reviewers`, `labels` |
| `deliver.after` | `feedback.skills`. The lead runs these skills on the delivered PR and handles what they report like review comments |
| `deliver.readiness` | Delete. Runs now wait for CI and review after delivery. To end at the PR instead, set `"feedback": {"wait": false}` |
| `deliver.acceptRemotePaths` | Delete. If someone else pushes to the PR branch, the lead merges it into the run and verifies again |
| `spec.approval` | Delete. `policy` becomes supervised mode: `--supervised` or `LOOP_SPEC_MODE=supervised` skips the approval and still asks blocking questions ([step 5](#5-update-agent-sdk-hosts)) |
| `phases.*`, `roles.*`, `evidence.*` | Delete. Move the behavior into your repository's `CLAUDE.md` or a project skill ([step 4](#4-move-customizations)) |

8.0 adds one key with no 7.x equivalent: `feedback.reviewWaitMinutes`. It sets how
long a run waits for requested reviewers after CI passes. The default is 30.

Keep a workspace's `.loop-spec/workspace.json` as it is; 8.0 reads the same
`{"repos": [{"name", "path"}]}`. 8.0 does not scan for clones itself: when the file is
missing, the lead writes it for the clones the request spans before it starts the run.

## 4. Move customizations

7.x let you swap the role skills and set per-role models. 8.0 has no roles. A lead
follows one skill and dispatches three agents: implementer and simplifier on Sonnet,
reviewer on Opus.

- **Checks.** Name your test, lint, and build commands in `CLAUDE.md` or `AGENTS.md`.
  The lead copies them into the plan, and 8.0 runs them with `bash -c` from the
  repository root. 7.x read them from manifests instead.
- **Review or house rules.** Write them in `CLAUDE.md`. The lead passes them to each
  agent it dispatches.
- **A custom role skill.** Keep it as a project skill. For work on the delivered PR,
  list it in `feedback.skills`.
- **Per-role models and effort** (`LOOP_SPEC_MODEL_*`, `LOOP_SPEC_EFFORT_*`). Delete
  them. Agent models are fixed in the agents' frontmatter. The lead runs on your
  session's model.

## 5. Update Agent SDK hosts

Skip this step if you only use Claude Code.

- If your host relays questions to a person, replace `spec.approval: policy` with
  supervised mode: `LOOP_SPEC_MODE=supervised`, or the example's `--supervised`. The
  run skips the criteria approval and asks only questions that are costly to get wrong.
- Replace `--answer-policy default` and the example's `--auto` with autonomous mode. Set `LOOP_SPEC_MODE=autonomous` in
  `ClaudeAgentOptions(env=...)`, or pass `--autonomous` to
  [examples/sdk-plugin](../examples/sdk-plugin/README.md). The run never asks and
  records the defaults it chose as assumptions.
- Delete `--spec-approval` from runner calls.
- Delete `LOOP_SPEC_PHASE_MODEL_*`. The example's `--phase-model PHASE=MODEL` now
  switches the lead's model itself. The recommended setup is
  `--model opus --phase-model execute=sonnet`.
- Delete `LOOP_SPEC_PLUGIN_DIRS`. The example's `--plugin DIR` still loads other
  plugins.
- If you used `examples/supervisor/` or `loop_spec.sdk_runner`, move to
  `examples/sdk-plugin/`. Both were removed.
- Drop any `--assignee @me` workaround: 8.0 opens PRs without an assignee.
- Read the phase from the run's `events.jsonl` (the last `phase_start` record), not from
  `state.json`.
- For pause and resume, wrap-up, and runs across repositories, see the README's
  [On the Agent SDK](../README.md#on-the-agent-sdk) section.

Keep your result reader as it is. 8.0 writes the same schema-1 `result.json`,
`last-result.json`, `LOOP_SPEC_RESULT`, and `LOOP_SPEC_NEXT` lines, in the same
places. Two differences in content:

- `reviewed` levels are always `unattested`, and `outstanding` is always empty.
- New top-level fields carry the spec's `assumptions` and `decisions`, each criterion's
  result (`criteria`, `criteriaSha`), and the review's `caveats`.
- Each delivery target gains `ci` and `reviews`: the PR's CI outcome and reviewer
  verdicts.

## 6. Check the migration

1. Confirm no 7.x keys remain:

   ```bash
   grep -nE '"(deliver|spec|roles|phases|evidence)"' .loop-spec/config.json
   ```

   No output means the config is clean.

2. Make a small change on a scratch request, for example:

   ```
   /loop-spec:micro Fix the typo in the README's install section
   ```

   Expect a PR against your `base` branch, with your `branchPrefix` and reviewers.
   The run then waits for CI, and ends once the checks pass and any requested review
   is in.

## What you will notice in 8.0

- The lead drives the run. `loop-spec status` names the next step; the program no
  longer issues every step.
- After the PR opens, `loop-spec feedback` waits for CI and reads the review. The lead
  fixes failures and comments, or answers questions, then delivers again. There is
  no round limit.
- If origin moves before delivery, `deliver` refuses. `loop-spec sync` merges what
  moved, and the lead verifies again. 7.x merged and re-verified on its own.
- Run state lives in `<repo>/.loop-spec/runs/<slug>/`. The state home
  (`~/.loop-spec`, or `LOOP_SPEC_HOME`) keeps only the copies that 7.x hosts read.
- The phase stream keeps 7.x's format: `LOOP_SPEC_PHASE_START` and `_END`, `[PHASE]`
  lines, and `events.jsonl`.

## Stay on 7.x

7.9.0 is the last 7.x release. The `7.x` branch holds it and takes hotfixes. To pin
the marketplace to it:

```
/plugin marketplace remove loop-spec-marketplace
/plugin marketplace add aztechead/loop-spec#7.x
/plugin install loop-spec@loop-spec-marketplace
```

Use the same commands to roll back after an upgrade. Runs started on 8.0 do not
carry over to 7.x.
