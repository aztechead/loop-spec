# Docs for humans (maintain and operate) — canonical prompt directive

Single source of truth for the docs-for-humans directive that every **document-producing
phase dispatch** must carry. It is the fourth member of a set. The laziness ladder
(`skills/shared/laziness-ladder.md`) governs *how much* code exists. Design for change
(`skills/shared/design-for-change.md`) governs *where its boundaries sit*. Code for humans
(`skills/shared/human-code.md`) governs *how the code reads to the next person who opens
the file*. This one governs *the markdown that person reaches for when the code is not
enough*. `tests/human-docs-coverage.test.sh` enforces the wiring; `lib/doc-tells.sh`
measures one corner of the content.

The plugin's output is not just code. Every cycle also writes markdown: SPEC, PLAN,
PATTERNS, VERIFICATION, the reviewer's guide, a PR body, commit messages, and whatever
README, guide, or runbook the change itself makes true or false. A person maintains and
operates all of it long after the run ends. That artifact class had three deterministic
gates on its STRUCTURE (`lib/artifact-lint.sh`), its GROUNDING (`lib/grounding-lint.sh`),
and its SENTENCES (`lib/plain-language-lint.sh`), and nothing at all on whether a human
could use it.

## The two jobs a document does

Every document this cycle writes serves one of two readers, and it must know which:

- **Maintain.** Someone is about to change this system and needs to know why it is the way
  it is, what will break, and which decision already got made and lost. Their failure mode
  is re-deriving a decision from scratch, or reversing it without knowing it was one.
- **Operate.** Someone is running this system right now, possibly at 03:00, possibly for
  the first time. Their failure mode is a command that does not run, a prerequisite nobody
  named, or a step whose success they cannot recognise.

Prose that serves neither reader is decoration. Prose that tries to serve both in the same
paragraph serves neither — the reader has to change mental gears mid-page.

## Relevant phases

- **SPEC / spec-writer** — SPEC.md is read by a human deciding whether the work is right (`agents/spec-writer.md`).
- **PLAN / planner** — the plan names the docs the change makes false; a doc task is a task (`agents/planner.md`).
- **EXECUTE / implementer** — every rung: team (`agents/implementer.md`,
  `skills/shared/team-prompts/implementer.md`), subagent (`skills/shared/execute-subagent.md`),
  loop-fleet (`lib/plan-to-loop.sh`), workflow (`lib/workflows/execute-dag.js`).
- **VERIFY / code-reviewer** — the docs-for-humans pass (`agents/code-reviewer.md`, `skills/verify/SKILL.md` Step 7.66).
- **Main thread** — `hooks/team/human-code-inject.sh` at SessionStart, toggled by `skills/settings/SKILL.md` (`human-code`).

## The principles

1. **Name the reader, and what they can do when they finish.** A document that does not
   know who it is for cannot be judged, cannot be pruned, and grows by accretion. One line
   at the top — who this is for, what they will be able to do — is the cheapest
   maintenance instrument there is.
2. **One document, one job.** The four documentation modes (Daniele Procida's Diátaxis:
   *tutorial* to learn, *how-to* to get a task done, *reference* to look a fact up,
   *explanation* to understand why) fail when they are blended: a how-to that stops to
   explain theory loses the person mid-task, and a reference padded with narrative buries
   the fact they came for. Pick the mode the reader needs and hold it; link to the others.
3. **Operable means runnable.** A procedure a person is meant to follow states its
   prerequisites first (access, tools, versions, where the secret lives), then the exact
   command — copy-pasteable, one instruction per step — then what success looks like, then
   what to do when the step fails. A command whose output nobody described cannot be
   checked by the person running it. One document, one failure mode; a runbook that
   branches on everything is a runbook nobody finishes.
4. **Cite, never copy.** Prose that restates what the code already says is the fastest
   thing in the repository to go stale, and stale documentation is worse than none because
   it is wrong with authority — the reason this project removed its generated code map in
   2.35 (CLAUDE.md). Point at `file:line` and let the reader read the truth. Copy a snippet
   only when the reader cannot run the command that produces it, and say where it came
   from.
5. **The doc ships in the diff that changes the behavior.** A change that makes a document
   false has not finished until that document is true again — README, help text, runbook,
   configuration table, whichever a human actually operates from. Docs live in the repo
   and are reviewed with the code (docs-as-code); a follow-up task to fix the docs is the
   deferral this project already refuses (`skills/shared/no-deferral.md`).
6. **Write the document the project will maintain.** Volume is not value. Prefer one page
   a maintainer will keep true over five that decay by the next release, and never invent
   a documentation convention the repository does not have — an ADR set, a docs site, a
   per-module README — inside an unrelated change. Where the repository does keep decision
   records, a decision needs its context and its consequences, not just its outcome
   (Michael Nygard, *Documenting Architecture Decisions*, 2011).
7. **Every claim about this codebase is grounded.** A generated document's characteristic
   defect is being locally plausible and globally wrong: a paragraph that reads perfectly
   and describes behavior no file implements. Cite the file, run the command, paste the
   output (`skills/shared/grounding-protocol.md`). Never describe what the code "probably"
   does.
8. **Write for a reader in a hurry.** Headings that answer questions, short paragraphs,
   tables for facts, lists for steps. Sentence-level readability — short sentences, active
   voice, plain words — is `skills/shared/plain-language.md`'s contract, and it applies to
   every document this one governs.

## What is machine-checked, and what is not

`lib/doc-tells.sh` measures three defects that are decidable from the text and the tree.
Everything else on this page is a judgment, and the probe has no opinion on it. Nothing in
this table may be claimed as enforced when the "Machine-checked" column says no.

| # | Rule | Machine-checked? |
|---|---|---|
| 1 | Name the reader and the job | **No.** A judgment about a specific document's audience. |
| 2 | One document, one mode | **No.** Telling a how-to from an explanation is a reading, not a string property. |
| 3 | Operable: prerequisites, exact command, expected output, failure branch | Partially — `undefined-placeholder` catches a command holding a placeholder the page never explains. Whether the expected output is stated is not checkable. |
| 4 | Cite, never copy | **No.** Whether a snippet earns its place depends on what the reader can run. |
| 5 | The doc ships with the change | **No.** Which document a behavior change makes false is exactly the judgment. |
| 6 | Write the doc the project will maintain | **No, and never will be.** |
| 7 | Claims are grounded | Partially — `dead-link` and `stale-ref` catch a reference to a file that is not there; `lib/grounding-lint.sh` covers the phase artifacts' `## Grounding` sections. A grounded-looking claim about real files stays a judgment. |
| 8 | Written for a reader in a hurry | Partially — `lib/plain-language-lint.sh` counts sentence and paragraph length; structure is a judgment. |

The three checks:

- `dead-link` — a relative markdown link whose target is not on disk.
- `stale-ref` — an inline-code path the tree no longer holds, fired only where the project
  keeps files of that kind (the directory exists and git tracks the same extension in it).
- `undefined-placeholder` — a placeholder inside a shell block whose words appear nowhere
  in the document's prose, so the reader cannot know what to substitute.

## Known false-positive sources (report them, do not hide them)

Measured across this repository's own 170 markdown documents: **181 findings**, of which
149 sit in delivered feature artifacts (SPEC/PLAN/PATTERNS from closed cycles, frozen
records of what was true then) and 32 in live documents. The live findings were sampled and
were real: `tests/smoke.sh` renamed years ago, `lib/state-write.sh` deleted, a relative link
written as if from the repository root. The known misfires:

- **A design artifact naming a file the change has not created yet** flags until the file
  exists. That is noise at SPEC and the check working at VERIFY, which is why the reviewer
  path is `doc-tells.sh diff <base>` — only what the change introduced.
- **A frozen record** (a delivered feature's PLAN.md, an audit dated last year) flags for
  every path the repository has since moved. Changelog-shaped files (`CHANGELOG.md`,
  `HISTORY.md`, `NEWS.md`, `RELEASES.md`) are skipped outright for this reason; other
  historical documents are not, because nothing in the text says they are history.
- **A path named because it is gone** is suppressed only when a neighbouring sentence says
  so ("no longer", "removed", "replaced by", "none of them do"). Phrase the absence some
  other way and the check flags a correct sentence.
- **`stale-ref` is deliberately conservative**: no first-segment directory, no tracked file
  of that extension, no extension at all, or a templated path (`docs/{slug}/SPEC.md`) means
  no finding. It under-reports on purpose — a lint that fires on correct documents teaches
  people to ignore it.

## Resolving the probe (`<probe_dir>`)

The probe ships inside the plugin; a dispatched agent's working directory is the target
repository, so a bare `lib/doc-tells.sh` resolves to nothing. Every dispatch site
substitutes a real absolute path before the directive goes out — the same table that
governs `house-style.sh` and `duplication-scan.sh`:

| Site | How it resolves |
|---|---|
| Skill-context prompts (`execute-subagent.md`, `team-prompts/implementer.md`) | `${CLAUDE_SKILL_DIR}/../../lib` |
| `lib/plan-to-loop.sh` | its own directory, from `BASH_SOURCE` |
| `lib/workflows/execute-dag.js` | the injected `skillDir` arg |
| `hooks/team/human-code-inject.sh` | its own directory, from `BASH_SOURCE` |
| `agents/implementer.md`, `agents/code-reviewer.md` | the `probe_dir` brief input |

When no path is available the sentence naming the probe drops out and the directive stands
on its own: open every document the change touches and follow its links yourself.

## Named carve-outs

Never cut, and never counted against a document's budget:

- **Machine-read contracts** — frontmatter, the phase artifacts' required section headings
  (`lib/artifact-lint.sh` enforces them), `EVID-NNN` citation lines, schema tables.
- **License and attribution blocks**, and any legally required notice.
- **The repository's own documentation conventions** — a project that writes a header block
  on every script keeps writing them; matching the neighbors outranks this page's taste,
  exactly as it does for code.
- **A deliberately frozen record** — a delivered cycle's artifacts, a dated audit, a
  changelog entry. Correct it only when someone will read it as current.

## Relationship to the other directives

- The ladder cuts speculative artifacts, and a document nobody will maintain is one. But
  YAGNI never cuts the doc a shipped behavior change makes necessary: principle 5 outranks
  it, the same way the ladder never cuts a seam.
- Code for humans governs comments; this governs documents. They agree on the rule that
  matters: say what the code cannot, never restate what it already says.
- Plain language governs how a sentence reads. This governs whether the document should
  exist, who it is for, and whether a person can act on it. A document can pass every
  readability check and still be useless.
- The grounding protocol supplies the evidence a claim needs; principle 7 is that protocol
  applied to prose a human will trust without checking.

## Compact directive (read this file; do not paste it into a prompt)

Dispatch names this file and the resolved probe. A SessionStart hook does not reach a
dispatched agent, so the prompt still says to Read this file.

> DOCS FOR HUMANS (the markdown is a deliverable too — on by default). Every document you
> write is maintained and operated by a person after this run ends. Name its reader in the
> first line — someone about to CHANGE this system, or someone about to RUN it — and hold
> one job per document: a how-to gets a task done, a reference states facts, an explanation
> says why. Blending them serves neither reader. A procedure states its prerequisites, then
> the exact copy-pasteable command, then what success looks like, then what to do when the
> step fails; a command whose expected output you did not describe cannot be checked by the
> person running it. Cite, never copy: point at `file:line` instead of restating what the
> code says — stale prose is worse than none because it is wrong with authority. If your
> change makes a document false (README, help text, runbook, config table), fix it IN THIS
> DIFF; a follow-up doc task is deferred scope. Ground every claim: never write what the
> code "probably" does. Prefer one page the project will keep true over five that decay,
> and never invent a documentation convention this repository does not already have. Before
> you report DONE run `bash <probe_dir>/doc-tells.sh scan <the markdown you touched>`: it
> flags a relative link with no target, an inline-code path the tree no longer holds, and a
> command holding a placeholder your prose never explains. NEVER cut: frontmatter and
> machine-read contract sections, required artifact headings, EVID citation lines, license
> blocks, or the repository's own documentation conventions.

## Sources

- Daniele Procida, **Diátaxis** (https://diataxis.fr) — the four documentation modes and
  the harm of blending them in one page.
- Michael Nygard, **Documenting Architecture Decisions** (2011) — a decision record carries
  context and consequences, not only the outcome.
- **Docs-as-code** practice — documentation lives in the repository, changes in the same
  pull request as the behavior, and is reviewed like code.
- **On-call runbook practice** — one failure mode per runbook, prerequisites up front,
  expected output beside each command, an explicit branch for each failure.
- This repository's own evidence — the generated code map removed in 2.35 because a rotted
  map is wrong with authority (CLAUDE.md), and the 181-finding survey recorded above.
