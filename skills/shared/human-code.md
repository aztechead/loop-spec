# Code for humans (house style over habit) — canonical prompt directive

Single source of truth for the code-for-humans directive that every **code-producing
phase dispatch** must carry. It is the third member of a set: the laziness ladder
(`skills/shared/laziness-ladder.md`) governs *how much* code exists, design for change
(`skills/shared/design-for-change.md`) governs *where its boundaries sit*, and this one
governs *how it reads to the next person who opens the file*. Enforced by
`tests/human-code-coverage.test.sh`.

Code is read far more often than it is written, and the reader is a person with a
half-loaded mental model of the module. Generated code fails that reader in a specific,
recognisable way: it is correct, and it looks nothing like the code around it. Different
naming, different error idiom, a docstring on every function in a module that has none, a
comment above every line explaining the line. That is the failure this directive addresses.

Relevant phases:
- **PLAN / planner** — tasks name the files, so the brief can carry their conventions (`agents/planner.md`).
- **EXECUTE / implementer** — every rung: team (`agents/implementer.md`,
  `skills/shared/team-prompts/implementer.md`), subagent (`skills/shared/execute-subagent.md`),
  loop-fleet (`lib/plan-to-loop.sh`), workflow (`lib/workflows/execute-dag.js`).
- **VERIFY / code-reviewer** — the code-for-humans pass (`agents/code-reviewer.md`).
- **Main thread** — `hooks/team/human-code-inject.sh` at SessionStart, toggled by `skills/human-code/SKILL.md`.

## The principles

1. **The surrounding code is the style guide.** Read the neighbors before writing a line —
   naming, error idiom, test structure, file layout, import order, how they log, how they
   fail. The house convention outranks any external guide, and it outranks your defaults
   even when you would have chosen differently. Disagreeing with a convention is a review
   finding, never a licence to deviate inside your diff. Where the convention is not
   obvious, measure it: `<probe_dir>/house-style.sh probe <files>` reports comment density,
   doc-comment usage, indentation, naming case, and line length from the actual neighbors,
   and says `unknown` rather than guessing. Then judge the result:
   `<probe_dir>/house-style.sh compare <files>` holds each file out of its own baseline and
   names where it deviates from its same-language neighbors — indent, naming, quotes,
   semicolons, module system. The two modes answer different questions and are not
   interchangeable: `probe` describes the neighbourhood *including* the target, so a file
   that breaks every convention around it reports AS the convention, its deviation averaged
   into the baseline it is measured against. Only `compare` can name a deviation, which is
   what the severity rule below depends on.
2. **Comments carry why, never what.** The code already says what it does; a comment that
   restates it goes stale the first time the line changes and misleads the reader after
   that. Spend a comment on what the code cannot say: a constraint that is not visible
   locally, a decision and the alternative it beat, a workaround and the reason it exists,
   a landmine for the next person. `lib/comment-tells.sh` catches the three shapes that
   are wrong in any codebase — a comment narrating the diff, a comment narrating history,
   and a one-line comment whose next line of code says the same thing.
3. **Comment density matches the file, not an absolute.** Density is set by the neighbors.
   A module that documents every public function gets a documented function; a module that
   documents none does not suddenly acquire a docstring convention from your diff. "Fewer
   comments" is not the goal — *the file's* comment budget, spent on why, is the goal.
4. **Naming does the work a comment would.** A name that states intent deletes the comment
   that would have explained it. Reach for the name first; keep the comment only when the
   why survives the rename.
5. **Read it like a reviewer, not a compiler.** Early return over nested branch, one idea
   per function, control flow that reads top to bottom. If explaining the code takes a
   paragraph, the code is the problem — this is the ladder's "clever is suspect" seen from
   the reader's chair.
6. **The diff is written for the reviewer.** No drive-by reformatting, no unrelated
   renames, no churn that buries the real change. A reviewer should be able to read the
   diff and see only the decision you made.

## Resolving the probes (`<probe_dir>`)

The probes ship inside the plugin; a dispatched agent's working directory is the target
repository. A bare `lib/house-style.sh` therefore resolves to nothing, so every dispatch
site substitutes a real absolute path before the directive goes out. The same table governs
the ladder's `duplication-scan.sh` (`skills/shared/laziness-ladder.md`), which every one of
these sites carries alongside these two:

| Site | How it resolves |
|---|---|
| Skill-context prompts (`execute-subagent.md`, `team-prompts/implementer.md`) | `${CLAUDE_SKILL_DIR}/../../lib` |
| `lib/plan-to-loop.sh` | its own directory, from `BASH_SOURCE` |
| `lib/workflows/execute-dag.js` | the injected `skillDir` arg |
| `hooks/team/human-code-inject.sh` | its own directory, from `BASH_SOURCE` |
| `agents/implementer.md`, `agents/code-reviewer.md` | the `probe_dir` brief input |

When no path is available the sentence naming the probe drops out and the directive stands
on its own: read three neighboring files end to end and follow them. The measurement is
what makes a convention *demonstrable* (and therefore blocking at VERIFY); the principle
does not depend on it.

## Named carve-outs

A blunt "comment less" rule would fight disciplines this repo already requires. These are
never cut, and never counted against the density budget:

- **`simplicity:` markers** — the laziness ladder requires a deliberate shortcut to name
  its ceiling and upgrade path in a comment.
- **File-header purpose blocks** where the codebase uses them (loop-spec writes one on
  every script: what it is for, usage, exit codes).
- **Marker comments** the project already reads: `TODO`, `FIXME`, `NOTE`, `HACK`, `XXX`,
  `SAFETY`, `SECURITY`, `WHY`.
- **Contract documentation** the spec or a public API requires — a published signature,
  an exit-code table, a schema note.
- **Any comment encoding a non-obvious why.** When in doubt, the why stays.

Section banners and numbered "Step N:" narration are judged against the neighbors, not
banned: they are noise in a file that has none and correct in a file built on them.

## Relationship to the other two directives

The ladder cuts speculative *artifacts*; design-for-change protects *seams*; this directive
protects *legibility*. None of the three overrides the others, and where they appear to
collide the resolution is fixed:

- Matching the house style never justifies duplicating a helper the ladder would reuse.
  When the neighbors themselves hold a second copy, the house style is the *shape* to
  match, never a licence to add a third — `lib/duplication-scan.sh` names the file the
  block already lives in, and reuse means calling it or lifting the shared part out.
- Matching the house style never justifies cutting a seam, and a seam's boundary is not
  "extra indirection" because the neighbors lack one.
- The ladder's `simplicity:` marker and this directive's comment budget do not conflict:
  the marker is an exempt carve-out, listed above.
- A convention that is genuinely wrong is a **finding**, reported in self-review or by the
  reviewer, and fixed in its own change — never fixed silently inside an unrelated diff.

## Canonical compact directive (inline this verbatim into dispatch prompts)

> CODE FOR HUMANS (house style over habit — on by default). Code is read far more than it
> is written; the diff must read like the code around it. Read the neighbors FIRST and
> match them: naming, error idiom, test structure, file layout, import order — the house
> convention outranks your defaults even when you would have chosen differently, and
> disagreeing with it is a review finding, never a licence to deviate. Where the convention
> is unclear, measure it: `bash <probe_dir>/house-style.sh probe <your files>` reports comment
> density, doc-comment usage, indentation, and naming case from the actual neighbors. Before
> you report DONE, judge your own work with `bash <probe_dir>/house-style.sh compare <files
> you touched>`: it holds each file out of its own baseline and names where it deviates from
> its same-language neighbors (indent, naming, quotes, semicolons, module system). `probe`
> pools your file into the sample and therefore can never show you a deviation — only
> `compare` can.
> Comments carry WHY, never what: a constraint that is not visible locally, a decision and
> the alternative it beat, a workaround and its reason. Never narrate the code, restate a
> signature, announce the edit ("Added…", "Updated…"), or narrate history ("previously…",
> "renamed from…") — `bash <probe_dir>/comment-tells.sh scan <files>` catches those three. Comment
> DENSITY matches the file, not an absolute: do not add docstrings to a module that has
> none, or strip them from one that documents everything. A good name deletes a comment —
> reach for the name first. Early return over nested branch; one idea per function. Keep
> the diff readable: no drive-by reformatting, renames, or churn that buries the change.
> NEVER cut: `simplicity:` shortcut markers, file-header purpose blocks where the codebase
> uses them, TODO/FIXME/NOTE/HACK/SAFETY/SECURITY markers, spec- or API-required contract
> docs, or any comment encoding a non-obvious why.
