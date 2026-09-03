# Prompt normalize - front-of-entry input rewrite contract

Rewrite implementer-authored prose ONCE, at the first loop-spec surface it crosses,
so every route starts from the strongest faithful statement of the ask. Reader: the
lead executing an entry skill (cycle, intake, micro, debug) at the moment it acquires
the implementer's input, before any parsing, extraction, or classification uses it.
One inline pass by that lead - non-interactive, no subagent, no questions, no delta
shown; the rewritten text silently replaces the original as the input everywhere
downstream (titles, slugs, drafts, provenance blocks all derive from it). Ordering:
the pass runs after the entry's own token stripping and source classification (those
inspect the raw input) and before any extraction, drafting, or title derives from it
- the table below names the exact seam per entry.

## What gets rewritten, what passes through byte-for-byte

Rewrite only free prose: a feature description, a pasted message or ticket body, a
task sentence, a vague symptom report. Everything else travels verbatim:

- **Artifacts** - stack traces, error output, code blocks and snippets, log lines,
  commands, failing-test names, file paths, URLs, identifiers, numbers, and quoted
  acceptance criteria. These are evidence; paraphrasing one destroys it.
- **Invocation tokens** (`autonomous`, `new`, `style:...`, `profile:...`, `backlog`,
  `--no-run`) and file-path arguments - they are grammar, not prose.
- **SPEC-shaped sources** (an `ambiguity_scores` frontmatter block, or the SPEC.md
  section skeleton) - the SPEC phase's ingest gate already normalizes those;
  rewriting a spec into a spec adds nothing but drift.
- **Input another loop-spec skill produced** (an escalation brief from micro, a
  draft from intake) - it was normalized at its own entry; a second pass only
  drifts. Normalize implementer input once, never loop-spec output. An auto-routed
  request is NOT loop-spec output: auto forwards the implementer's prose verbatim,
  so the routed-to skill runs the pass.

## The rewrite moves

1. **Pressure language at normal volume.** Strip caps-lock emphasis and stacked
   MUST/NEVER/CRITICAL markers; state the one or two real constraints plainly, with
   their reason where the source gives one.
2. **Hedges off real requirements.** "Try to include X if possible" becomes
   "include X" only when the surrounding text shows X is required; genuine
   optionality stays optional.
3. **Choreography becomes outcomes.** Step-by-step method scripts for judgment work
   collapse to the goal, the constraints, and how success is checked. Keep exact
   sequences only where order genuinely matters (destructive commands, auth flows).
4. **Say each thing once.** Merge duplicate asks, drop generic virtues ("be accurate
   and thorough"), drop grader vocabulary; a repeated instruction is kept in its
   strongest single form.
5. **Prohibitions keep their reasons.** A "never do X" carrying a reason or real
   constraint stays, reason beside it; a bare style tic is restated positively in
   one line.
6. **Surface the implicit structure.** Make the goal, constraints, and acceptance
   signals the source actually contains explicit and separable - without adding any.

## Hard rules

- **Normalize, never invent.** No new requirements, constraints, criteria, or
  assumptions; every statement in the output must be traceable to the input. Gaps
  stay gaps - the ambiguity gate, DISCUSS, and micro's one question own resolution,
  and a rewrite that fills a hole has fabricated a goal the implementer never stated.
- **Context is never cruft.** Audience, product, environment facts, quality bar,
  and the reasons behind constraints all survive; never justify a cut by length.
- **Clean input passes unchanged.** A normalize that finds nothing changes nothing.

## Where the pass sits

| Entry | The pass runs |
|---|---|
| `skills/cycle/SKILL.md` | on a free-prose feature description, before `cycle-driver.sh start` |
| `skills/intake/SKILL.md` | on the acquired source, after the SPEC-shaped check, before extraction |
| `skills/micro/SKILL.md` | on the task description, before done-criteria are derived |
| `skills/debug/SKILL.md` | on prose symptom text, before `debug-init.sh init` |

`skills/auto/SKILL.md` routes verbatim; the target skill normalizes.
`tests/prompt-normalize-coverage.test.sh` pins this wiring.
