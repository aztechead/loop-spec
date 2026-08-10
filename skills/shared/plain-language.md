# Plain language (readability contract) — canonical prompt directive

Single source of truth for the plain-language directive that any **prose-producing**
surface may carry: SPEC/PLAN/PATTERNS/VERIFICATION prose, PR bodies, commit messages,
and code comments. It is READABILITY only. It does not overlap
`lib/comment-tells.sh`, which catches a different failure — a comment that narrates
the diff, narrates history, or restates the next line of code, not a comment that is
merely hard to read. Enforced (where machine-checkable at all) by
`lib/plain-language-lint.sh`; test coverage in `tests/lib/plain-language-lint.test.sh`.

## Copyright note

ASD-STE100 ("Simplified Technical English") is a specification owned and copyrighted
by the ASD (AeroSpace and Defence Industries Association of Europe). This repo does
**not** reproduce its approved-word dictionary and makes **no claim of conformance**
to it. What follows below, labelled STE-informed, is loop-spec's own short,
independently written summary of ASD-STE100's publicly documented STRUCTURAL rules —
sentence length, one instruction per sentence, active voice, avoiding "/" as
shorthand for "and/or" — plus loop-spec's own substitution list, word-substitution
list, and stock-phrase list, none of it copied from ASD-STE100's dictionary. Any
artifact or prompt that cites this contract must say **"STE-informed"**, never
**"STE-compliant"** or **"STE-conformant"** — this repo has not run ASD-STE100
conformance checking and is not entitled to that claim.

## Orwell's six rules (source, verbatim)

From George Orwell, *"Politics and the English Language"* (1946):

1. Never use a metaphor, simile, or other figure of speech which you are used to
   seeing in print.
2. Never use a long word where a short one will do.
3. If it is possible to cut a word out, always cut it out.
4. Never use the passive where you can use the active.
5. Never use a foreign phrase, a scientific word, or a jargon word if you can think
   of an everyday English equivalent.
6. Break any of these rules sooner than say anything outright barbarous.

Rule 6 is the escape hatch: every rule below yields to sense. A probe can flag a
candidate violation; it cannot judge whether breaking the rule was the right call in
context. That judgment stays with the writer and reviewer.

## The rules this repo adopts, and what enforces each one

Every row states plainly whether a deterministic check exists. A rule with no
check name in the "Machine-checked" column is **guidance only** — nothing in this
repo currently enforces it, and no artifact or prompt may claim otherwise.

| # | Rule | Source | Machine-checked? |
|---|---|---|---|
| 1 | Avoid tired metaphors and stock phrases ("at the end of the day", "move the needle"). | Orwell rule 1 | Yes — `stock-phrase` (curated phrase list, not exhaustive; catches only listed phrases) |
| 2 | Prefer a short, plain word over a long, bureaucratic one where one exists (utilize→use, facilitate→help, ...). | Orwell rule 2; STE-informed (STE restricts vocabulary to one approved word per meaning — this repo does not reproduce that dictionary, see the copyright note above) | Yes — `long-word` (curated substitution list, ≥20 pairs, not exhaustive) |
| 3 | Cut every word that adds nothing. | Orwell rule 3 | **No.** "Adds nothing" is a judgment call about a specific sentence's information content, not a decidable string property — guidance only, left to the writer and reviewer. |
| 4 | Prefer active voice over passive. | Orwell rule 4; STE-informed (STE requires active voice) | Yes — `passive-voice` (regex: a form of "be" followed by a past participle; a heuristic, not a full grammatical parse — flags predicate adjectives that happen to end "-ed" and misses passive constructions that omit "be", e.g. some perfect-tense forms) |
| 5 | Prefer an everyday English word over a foreign phrase, Latin tag, or unexplained jargon term. | Orwell rule 5 | Partially — `foreign-phrase` catches a curated list of common Latin/foreign tags (e.g., i.e., vis-à-vis, per se, ad hoc, inter alia, et al., etc., a priori, de facto, status quo, vice versa, bona fide). "Unexplained jargon" is not machine-checkable — a jargon term this repo's own domain vocabulary needs (spec, grounding, deterministic, orchestrate) is not a violation, and telling that apart from unexplained jargon is a judgment call — guidance only for the jargon half of this rule. |
| 6 | Sense beats the rules — break any of the above sooner than write something barbarous. | Orwell rule 6 | **No, and never will be.** This is the rule that makes the other five judgment calls, not a check itself. |
| 7 | One instruction (or one short, complete thought) per sentence; keep sentences short — a *descriptive* sentence over ~25 words or a *procedural/imperative* sentence (an instruction, or a list step) over ~20 words is a candidate for splitting. | STE-informed (STE caps instruction sentences around 20 words and descriptive sentences around 25) | Yes — `long-sentence` (word count via regex tokenizer; sentence-type classification is a heuristic: a sentence is "imperative/procedural" when it is a list item or its first word is in a curated imperative-verb list, otherwise it is treated as descriptive) |
| 8 | Do not use "/" as shorthand for "and/or" between two words — write "and" or "or" and mean one of them. | STE-informed (STE bans "and/or" and slash constructions outright) | Yes — `slash-and-or` (curated literal pairs: `and/or`, `he/she`, `pass/fail`, ... — deliberately a curated list, not a generic `word/word` pattern, so file paths and version ranges like `lib/foo.sh` or `3.7/3.8` never false-positive) |
| 9 | Keep paragraphs short — a wall of unbroken prose (more than ~6 sentences with no break) is a candidate for splitting into sub-points or sub-headings. | STE-informed (STE caps paragraph length for scannability) | Yes — `long-paragraph` (sentence count per contiguous non-list, non-heading text block; sentence splitting is a regex heuristic, not a parser, and can misfire on abbreviations like "e.g." that contain a period) |
| 10 | Use the imperative mood for a procedural heading ("Install the plugin"), not a gerund ("Installing the plugin"). | STE-informed (STE writing-for-translation guidance: instructions are commands, not descriptions) | Yes — `gerund-heading` (curated list of ~29 common instructional gerunds; a single-word heading like "## Testing" is treated as a noun title, not a clause, and is not flagged) |

## The checks (`lib/plain-language-lint.sh`)

Eight checks, each deterministic, each emitting a distinct greppable message
prefixed with its own check name:

- `long-sentence` — sentence longer than 25 words (descriptive) or 20 words
  (imperative/procedural: a list item, or a sentence whose first word is a curated
  imperative verb).
- `passive-voice` — a form of "be" followed by a past participle.
- `long-word` — a word on the curated long/short substitution list (≥20 pairs).
- `foreign-phrase` — a foreign or Latin phrase on the curated list with an everyday
  equivalent.
- `stock-phrase` — a tired metaphor or stock phrase on the curated list (Orwell
  rule 1).
- `slash-and-or` — "/" used as shorthand for "and/or" between two words, from a
  curated literal-pair list.
- `long-paragraph` — a prose paragraph (not a heading, not a list) with more than 6
  sentences.
- `gerund-heading` — a markdown heading that opens with a gerund used as an
  instruction, where the imperative mood reads better.

None of these checks reproduces or depends on ASD-STE100's approved-word
dictionary. `long-word`, `foreign-phrase`, `stock-phrase`, and `slash-and-or` are
loop-spec's own short curated lists, written from scratch for this repo.

## Modes

```
plain-language-lint.sh prose    <file|-> [file...]   # markdown artifacts: SPEC.md, PLAN.md, ...
plain-language-lint.sh comments <file|-> [file...]   # #-comments (sh/py), python docstrings
plain-language-lint.sh text     -                     # stdin: PR bodies, commit messages
plain-language-lint.sh --rules                        # print every check name, one per line
```

`prose` mode skips fenced code blocks, table rows, link URLs (the link *label* is
still checked), inline code spans, and YAML frontmatter — none of that is prose.
`comments` mode extracts only `#`-comments (shell and python) and python
triple-quoted docstrings (a regex scan, not a parser); it never reads code.

## Output and exit contract (matches `lib/artifact-lint.sh` exactly)

One `FLAG <path>:<line>: <message>` per defect (`<message>` is
`<check-name>: <detail>`, so `grep 'passive-voice:'` isolates one check), then one
final line: `plain-language-lint: ok (<mode>: <path>)` or
`plain-language-lint: <n> flag(s) (<mode>: <path>)`.

Exit codes: 0 clean, 1 any flag (including unreadable/empty input — fail safe), 2
bad invocation. `--max-flags N` caps the number of `FLAG` lines printed (an extra
truncation line names how many were held back); the final flag count always
reports the true total, never the truncated one.

## ADVISORY ONLY — this is not a gate

`lib/plain-language-lint.sh` only ever reports. **It is never wired to block a
phase**, and its non-zero exit must never be treated as a hard failure by a skill,
hook, or phase script. Any call site that wires this into a gate is a separate,
deliberate change with its own review — not an implicit consequence of this
contract existing. Treat a flag as a suggestion a human or a later pass may act on,
the same way `lib/house-style.sh probe` reports without blocking.

## Known false-positive sources (report them, do not hide them)

This is a set of regex heuristics over natural-language text, not a parser or a
model judgment — so it will misfire in specific, nameable ways:

- `passive-voice` flags predicate adjectives that end in "-ed" ("the plan is
  detailed") as if they were passive constructions.
- `long-sentence` and `long-paragraph` both depend on a regex sentence splitter that
  breaks on every `.`/`!`/`?`; abbreviations containing a period (`e.g.`, `i.e.`,
  `etc.`) can fragment one real sentence into several short ones.
- Domain vocabulary this repo genuinely needs (`implement`, `component`,
  `requirement`) is deliberately **not** on the `long-word` list, because banning it
  would make every technical artifact in this repo unreadable-by-the-linter's-own-
  standard. The curated lists trade recall for precision on purpose.
- Dense technical specification prose triggers real, honest hits at a materially
  higher rate than ordinary prose — long compound sentences and passive
  constructions are common in spec writing. That is not a bug to tune away; it is
  the tool doing its job on writing that is, in fact, hard to read.
- `long-sentence`'s imperative/procedural classification treats every `- ` or
  numbered list item as imperative (the 20-word cap), on the theory that list
  items are usually instructions or steps. Measured against
  `docs/loop-spec/features/gdd/SPEC.md`, that assumption is wrong often enough to
  matter: most of that file's bulleted content is `- Decision: ...` and
  `- EVID-NNN: ...` citation entries, which are descriptive, not procedural. Of
  175 total flags on that file, 102 were `long-sentence`; 51 of those landed on a
  list line and got the 20-word cap, and 24 of those 51 (14% of all 175 flags)
  were between 21 and 25 words — they would not have flagged under the correct
  25-word descriptive cap. This is the tool's largest identified false-positive
  source and it is a real limitation of the "list item implies imperative"
  heuristic, not a rounding error: a citation-heavy or decision-log-heavy
  document will over-trigger this check specifically.
