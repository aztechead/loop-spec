---
name: rules
description: Use when the user says "add a rule", "list the rules", or "show RULES.md". Reads and writes .loop-spec/RULES.md (add/list/render/path). Do not use this to implement a feature; prefer a deterministic --check over a prose note.
argument-hint: '<add "<rule text>" [--check "<cmd>"] | list | render | path>'
---

# Rules Skill

Invoked as `/loop-spec:rules <subcommand> [args]`.

Manage reusable rules in `.loop-spec/RULES.md` through `lib/rules.sh`.
The user owns and maintains this file.
`hooks/team/rules-inject.sh` adds current rules to each session by default. `LOOP_SPEC_RULES=0` disables that injection.

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
RULES_LIB="${LOOP_SPEC_SKILL_DIR}/../../lib/rules.sh"
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

When a gate or verifier rejects the same class of mistake more than once, record a reusable rule.
Call `lib/rules.sh add`, or suggest `/loop-spec:rules add`.
Prefer a deterministic check when one can detect the mistake.

## Notes

- The file is markdown and human-owned; `lib/rules.sh` never rewrites existing rule text,
  only appends new bullets.
- Two layers: per-project (`.loop-spec/RULES.md`) and cross-project global
  (`$LOOP_SPEC_GLOBAL_RULES_FILE` else `~/.loop-spec/RULES.md`). Both are injected inside
  loop-spec projects (project first, global rules deduped against it); a project rule can
  restate a global one to pin phrasing. Nothing is ever injected outside loop-spec projects.
- Complements grill mode (front-load ambiguity) and discipline mode (behavioral
  gates), both toggled by `/loop-spec:settings`: grill lowers ambiguity going
  in, rules lower repeat-failure rate over time.
