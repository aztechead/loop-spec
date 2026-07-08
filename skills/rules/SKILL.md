---
name: rules
description: Manage the self-learning loop rules file (.loop-spec/RULES.md). Every repeated mistake becomes a permanent rule carried into future runs by the rules-inject SessionStart hook. Subcommands add/list/render/path. Prefer deterministic checks over prose notes.
argument-hint: '<add "<rule text>" [--check "<cmd>"] | list | render | path>'
---

# Rules Skill

Invoked as `/loop-spec:rules <subcommand> [args]`.

Implements the **self-learning loop**: a mistake should become a permanent, enforced
check, not a note that lives only in chat. Rules live in `.loop-spec/RULES.md`, a file
**you own and curate**. The `hooks/team/rules-inject.sh` SessionStart hook injects the
current rules into every session so the loop is held to its past lessons (default on;
`LOOP_SPEC_RULES=0` is the kill switch).

All mechanics are in `lib/rules.sh`; this skill is the thin command surface.

## Subcommands

- `add "<rule text>" [--check "<command>"] [--global]` - Append a rule. Idempotent on
  exact text. Pass `--check` with a deterministic command that fails when the rule is
  violated — **prefer a check over a prose note** (a check the compiler/tests/lint can
  enforce beats a sentence the model can rationalize around). `--global` writes the
  cross-project layer (`~/.loop-spec/RULES.md`) for lessons that travel everywhere.
- `list [--global]` - Print current rules (text only). Default: merged project + global
  (exact duplicates once); `--global`: global layer only.
- `render` - Print the injectable rules body (project file + a `## Global rules` section
  for global rules not already in the project file). Silent when both layers are empty.
- `path [--global]` - Print the resolved RULES.md path for the chosen layer.

## Procedure

Resolve the lib relative to this skill and pass the subcommand through:

```bash
RULES_LIB="${CLAUDE_SKILL_DIR}/../../lib/rules.sh"
bash "$RULES_LIB" <subcommand> "$@"
```

### add

1. Run `bash "$RULES_LIB" add "<rule>" [--check "<cmd>"]`.
2. Report whether it was `added` or already `exists`.
3. If the rule could be enforced by a command the user already has (a test, a linter, a
   typecheck), suggest re-running `add` with `--check` so the next loop enforces it
   deterministically.

### list / render / path

Run the corresponding `lib/rules.sh` subcommand and print the output verbatim.

## When the loop should add a rule

The cycle and its phases should call `lib/rules.sh add` (or suggest `/loop-spec:rules add`)
when a gate or verifier rejects the **same class** of mistake more than once — a repeated
spec-compliance miss, a recurring review finding, a flaky-by-construction test. Capture the
lesson as a rule so the next run cannot repeat it. One mistake, one permanent check.

## Notes

- The file is markdown and human-owned; `lib/rules.sh` never rewrites existing rule text,
  only appends new bullets.
- Two layers: per-project (`.loop-spec/RULES.md`) and cross-project global
  (`$LOOP_SPEC_GLOBAL_RULES_FILE` else `~/.loop-spec/RULES.md`). Both are injected inside
  loop-spec projects (project first, global rules deduped against it); a project rule can
  restate a global one to pin phrasing. Nothing is ever injected outside loop-spec projects.
- Complements [grill mode](../grill/SKILL.md) (front-load ambiguity) and
  [discipline mode](../discipline/SKILL.md) (behavioral gates): grill lowers ambiguity going
  in, rules lower repeat-failure rate over time.
