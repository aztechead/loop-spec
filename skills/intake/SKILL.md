---
name: intake
description: Turn ANY input into a cycle-ready spec draft and kick off the cycle. Feed it a Slack message, a Jira ticket, a .txt/.md file, a pasted email, or a bare prompt — anything that is not already SPEC.md-shaped. It faithfully restructures the source into a spec draft (never inventing scope), writes it to .loop-spec/intake/, and hands it to /loop-spec:cycle via the existing spec-file ingest path. Honors autonomous mode and inline style/new tokens (passed through to the cycle).
argument-hint: "<file path | pasted text (slack/jira/email/prompt/...)>  (optional pass-through tokens: autonomous, new, style:...; --no-run to stop after writing the draft)"
allowed-tools: Bash Read Write Glob Grep Skill AskUserQuestion
---

# Intake — anything → SPEC draft → cycle

The cycle already knows how to run from a pre-authored spec file (`/loop-spec:cycle
path/to/spec.md` → SPEC phase spec-file ingest: graph-ground, score the ambiguity gate,
normalize). What it cannot eat is a Slack thread, a Jira ticket, or a rambling prompt.
This skill is the converter in front of that path — and ONLY the converter (ponytail:
the ingest machinery already exists; do not rebuild it here). Scoring, normalization,
interviews, and gates all stay in the SPEC phase.

**The fidelity rule (CRITICAL): restructure, never invent.** Every requirement,
constraint, and decision in the draft must be traceable to the source text. Where the
source is silent, the draft stays silent — the ambiguity gate and DISCUSS exist
precisely to catch and resolve those holes (`gate_passed: false` +
`unresolved_dimensions` is the designed outcome for a thin source, not a failure of
this skill). An intake that pads a two-line Slack message into a confident 10-requirement
spec has fabricated a goal the user never stated — worse than useless, because
downstream gates will faithfully verify the fabrication.

## Step 1 - Acquire the source

Resolve `$ARGUMENTS` after stripping pass-through tokens (`autonomous`, `new`,
`style:...`, `--no-run` — remember them for Step 4):

1. **Remaining args resolve to a readable file** (`[[ -f "$arg" ]]`): read it. Any text
   format works (.txt, .md, .json export, log paste in a file).
2. **Remaining args are non-empty text**: that text IS the source (pasted Slack
   message, Jira description, email body, prompt).
3. **Empty**: ask ONE free-text AskUserQuestion for the content ("Paste the source —
   Slack message, ticket text, or a description of what to build."). Autonomous mode
   cannot self-answer an empty intake: abort with usage guidance
   (`skills/shared/autonomous-mode.md`, bare-invocation rule).

**Already SPEC-shaped?** If the source begins with an `ambiguity_scores` YAML
frontmatter block, or is a file that already carries the SPEC.md section skeleton
(`## Requirements` + `## Boundaries`), skip conversion entirely — go straight to Step 4
with the file path (write pasted text to the Step 3 path first). Converting a spec into
a spec adds nothing but drift.

## Step 2 - Extract (source → spec fields)

Read the source once as an editor, mapping what is actually there onto the spec
skeleton. Typical signal by source type — use as a reading guide, not a template to
fill at all costs:

| Source | Goal usually lives in | Acceptance usually lives in | Watch for |
|---|---|---|---|
| Jira ticket | summary/title | acceptance criteria field, DoD checklist | comments that amend the description — latest wins, note the override as a decision |
| Slack message/thread | first message | rare — usually absent | decisions made mid-thread ("let's do X instead"), @mentions assigning scope |
| Email | subject + first paragraph | rare | forwarded chains: newest layer is the ask, older layers are context |
| Prompt / txt notes | opening sentence | "should/must" sentences | wishlists — mark clearly-speculative items as out-of-scope candidates, don't promote them |

Extract into these buckets (leave a bucket EMPTY when the source has nothing for it):

- **Title** — one line, imperative, the user's ask in their own words where possible.
  This becomes the immutable original goal (`feature_title`) the ITERATE judge scores
  against, so keep it faithful to the source's intent, not your paraphrase of it.
- **Requirements** — each specific, testable statement the source makes. Keep the
  source's wording verbatim where it is already precise; tighten phrasing only where
  the source is conversational, and never tighten semantics.
- **Decisions already made** — anything the source has settled ("we agreed on
  Postgres", "per the thread, ship behind a flag"). These become the `<decisions>`
  block so DISCUSS/PLAN treat them as locked, not re-litigatable.
- **Constraints** — deadlines, stack pins, compatibility, perf numbers, "don't touch X".
- **Acceptance signals** — anything checkable the source states ("done when the
  export matches the old format", a listed DoD).
- **Boundaries** — explicit in/out-of-scope statements. Also collect the *implicit*
  outs: adjacent work the source mentions and defers ("we'll handle mobile later").
- **Open questions** — everything the source raises but does not answer. List them;
  do NOT answer them (that is the SPEC gate/DISCUSS's job — or the autonomous
  self-answer contract's, WITH its decision record; never intake's silently).

## Step 3 - Write the draft

Write to `.loop-spec/intake/{slug}.md` (`slug` = kebab-case of the title; `mkdir -p
.loop-spec/intake`). Structure — sections with no content are OMITTED, not padded:

```markdown
# {Title}

## Source
> Verbatim original, blockquoted in full (truncate only past ~200 lines, noting the cut).
Type: {slack message | jira ticket | email | file: path | prompt} — captured {ISO date}.

## Requirements
- {testable statement, source-faithful}

<decisions>
- {decision the source already settled, one per line}
</decisions>

## Constraints
## Boundaries (what NOT to do)
## Acceptance signals
## Open questions
- {question the source raises but does not answer}
```

The `## Source` block is the provenance trail: when DISCUSS or a PR reviewer wonders
"who asked for this?", the answer is in the artifact, verbatim. The SPEC phase copies
the draft into `.loop-spec/features/{slug}/spec-draft.md` and normalizes from there,
so this file is the durable record of what intake received and produced.

## Step 4 - Kick off the cycle

Default: hand off immediately —

```
Skill(loop-spec:cycle) with arguments: "{pass-through tokens} .loop-spec/intake/{slug}.md"
```

- Pass-through tokens (`autonomous`, `new`, `style:...`) go through verbatim — a Slack
  message describing a brand-new app runs `new autonomous .loop-spec/intake/{slug}.md`.
- The cycle's Step 3 branch 3 takes it from here: title from the draft's `# ` heading,
  SPEC phase in spec-file ingest mode, ambiguity gate scored on the draft itself. A
  thin source (most Slack messages) fails dimensions and lands in the designed
  resolution path: targeted questions in `step`/`interactive`, graph-grounded recorded
  assumptions in `auto`/autonomous.
- `--no-run`: stop after Step 3. Print the draft path and the exact cycle invocation
  the user would run. (Use when the user wants to eyeball the conversion first.)

## What this skill never does

- Never invents requirements, constraints, or acceptance criteria absent from the source.
- Never answers the source's open questions (SPEC/DISCUSS own resolution; autonomous
  self-answers happen THERE, with the decision record).
- Never runs the interview, scores ambiguity, or normalizes format — that is the SPEC
  phase's spec-file ingest mode, already built and gated.
- Never fetches remote content (offline by design, like the rest of the plugin): a Jira
  ticket or Slack thread arrives as pasted text or a saved file, not a URL.
