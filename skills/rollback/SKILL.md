---
name: rollback
description: Restore the working tree to a named checkpoint tag using history-safe git checkout, then commit the rollback as a new commit.
argument-hint: "[checkpoint tag or type]  (e.g. post-plan, or a full loop-spec-checkpoint-* tag)"
---

# ROLLBACK Skill

Invoked via `/loop-spec:rollback` or directly by the cycle lead when a phase needs to be undone.

## Checkpoint types

Six checkpoint types are created automatically by phase skills and `lib/checkpoint.sh`:

| Type | Created by | When |
|------|-----------|------|
| `post-discuss` | `skills/discuss/SKILL.md` | After `git commit SPEC.md` at the end of the DISCUSS phase |
| `post-plan` | `skills/plan/SKILL.md` | After `git commit PLAN.md` at the end of the PLAN phase |
| `post-execute` | `skills/execute/SKILL.md` | After the final merge step, before advancing to verify |
| `post-verify` | `skills/verify/SKILL.md` | After VERIFICATION.md is committed at the end of VERIFY |
| `pre-rollback` | `lib/checkpoint.sh` | Automatically, immediately before a rollback executes |
| `manual` | User via `/loop-spec:checkpoint <name>` | On demand, at any point during a session |

## Tag format

All checkpoint tags follow the pattern:

```
loop-spec-checkpoint-{type}-YYYYMMDD-HHMMSS
```

Example: `loop-spec-checkpoint-post-plan-20260528-143022`

Tags are created with `git tag` and are visible via `git tag -l 'loop-spec-checkpoint-*'`.

## Rollback mechanics

Rollback uses `git checkout TAG -- .` (NOT `git reset --hard`). This approach:

- Restores every tracked file to the state it had at the tag without rewriting history.
- Leaves the rollback itself as a new commit: `chore: NO_JIRA rollback to <tag>`.
- Keeps all intervening commits intact in `git log` for audit purposes.

The implementation is in `lib/checkpoint.sh` (`rollback` subcommand).

## Confirmation requirement

Before rollback executes, the user must confirm by typing **ROLLBACK** (all caps). In a skill context the confirmation is supplied by setting the environment variable:

```bash
LOOP_SPEC_ROLLBACK_CONFIRMED=1
```

If the variable is absent or not equal to `1`, `lib/checkpoint.sh` exits 1 with an error message and no changes are made.

## Inputs

- `tag` - the full checkpoint tag name to restore (e.g. `loop-spec-checkpoint-post-plan-20260528-143022`)

## Procedure

### Step 1 - List available checkpoints

```bash
git tag -l 'loop-spec-checkpoint-*' | sort
```

Present the list to the user so they can choose the target tag.

### Step 2 - Confirm

Ask the user to type **ROLLBACK** to confirm. Do not proceed until the literal string `ROLLBACK` is received. Set `LOOP_SPEC_ROLLBACK_CONFIRMED=1` once confirmed.

Before executing, create a `pre-rollback` checkpoint of the current state so the forward path can be recovered:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/checkpoint.sh" tag pre-rollback
```

### Step 3 - Run checkpoint rollback

```bash
LOOP_SPEC_ROLLBACK_CONFIRMED=1 bash "${CLAUDE_SKILL_DIR}/../../lib/checkpoint.sh" rollback <tag>
```

`lib/checkpoint.sh` will:
1. Run `git checkout <tag> -- .`
2. Stage all restored files via `git add -A`
3. Commit with message `chore: NO_JIRA rollback to <tag>`

### Step 4 - Confirm result

Print the new commit SHA and the list of restored files. Notify the user that history is preserved and the `pre-rollback` tag marks the state before this operation.

## Notes

- For schema-6 features the session is already inside the feature worktree when rollback runs; all repo-relative paths resolve correctly from cwd with no changes needed.
- `lib/checkpoint.sh` is the single source of truth for tagging and rollback logic.
- The `pre-rollback` tag created in Step 2 allows recovery if the rollback itself needs to be undone by rolling forward to that tag.
- Do not use `git reset --hard`; it destroys intervening commits and is explicitly out of scope for this skill.
