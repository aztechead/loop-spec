---
name: intake
description: "Use when converting pasted text or a local file into a spec draft before starting the cycle. Pass existing SPEC.md files to /loop-spec:cycle and stack traces to /loop-spec:debug."
argument-hint: "<file path | pasted text (slack/jira/email/prompt/...)>  (optional pass-through tokens: autonomous, new, style:...; --no-run to stop after writing the draft)"
allowed-tools: Bash Read Write Glob Grep Skill AskUserQuestion
---

# Intake — anything → SPEC draft → cycle

Convert a message, ticket, email, or notes into a draft for the cycle's spec-file input.
SPEC handles investigation, format validation, interviews, and approval. Do not duplicate those steps here.

**Restructure, never invent.** Every requirement, constraint, and decision must come from the source text.
Leave gaps unresolved. SPEC and DISCUSS resolve them later.
A thin source may correctly produce a non-empty `unresolved_questions` list.

## Step 1 - Acquire the source

Strip pass-through tokens (`autonomous`, `new`, `style:...`, `--no-run`) with the
shared parser — never by prose (one grammar, one implementation):

```bash
inv="$(bash "${LOOP_SPEC_SKILL_DIR}/../../lib/parse-invocation.sh" parse -- "$ARGUMENTS")"
# .autonomous/.greenfield/.style/.no_run are the Step 4 pass-through tokens;
# .spec_path (readable .md) or .title (everything else) is the remaining source.
```

1. **Remaining args resolve to a readable file** (`.spec_path` non-null, or `.title`
   is a single token with `[[ -f "$arg" ]]`): read it. Any text format works (.txt,
   .md, .json export, log paste in a file).
2. **Remaining args are non-empty text** (`.title`): that text IS the source (pasted
   Slack message, Jira description, email body, prompt).
3. **Empty**: ask ONE free-text AskUserQuestion for the content ("Paste the source —
   Slack message, ticket text, or a description of what to build."). Autonomous mode
   cannot self-answer an empty intake: abort with usage guidance
   (`skills/shared/autonomous-mode.md`, bare-invocation rule).

**Already SPEC-shaped?** If the source begins with an `unresolved_questions` YAML
frontmatter block, or is a file that already carries the SPEC.md section skeleton
(`## Requirements` + `## Boundaries`), skip conversion entirely — go straight to Step 4
with the file path (write pasted text to the Step 3 path first). Converting a spec into
a spec adds nothing but drift.

**Normalize the source** (`skills/shared/prompt-normalize.md`): after the SPEC-shaped
check, rewrite the source's free prose per that contract and use the rewritten text as
the source for Steps 2-3; quoted artifacts and criteria pass through byte-for-byte,
and input another loop-spec skill produced (a micro escalation brief) is already
normalized - skip the pass.

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

- **Title** — one line, imperative, in the normalized source's own words where possible.
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
> The normalized source, blockquoted in full (truncate only past ~200 lines, noting the cut).
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

The `## Source` block records the normalized source, including unchanged artifacts and quoted criteria.
SPEC copies this draft to `.loop-spec/features/{slug}/spec-draft.md` and normalizes its format there.
The intake file preserves the normalized source and extracted draft. It does not preserve the original prose before normalization.

## Step 4 - Start the cycle

Default: hand off immediately —

```
Skill(loop-spec:cycle) with arguments: "{pass-through tokens} .loop-spec/intake/{slug}.md"
```

- Pass-through tokens (`autonomous`, `new`, `style:...`) go through verbatim — a Slack
  message describing a brand-new app runs `new autonomous .loop-spec/intake/{slug}.md`.
- The cycle reads the title from the draft's `# ` heading and sends the draft to SPEC's ingest path.
  SPEC records unresolved questions from the draft.
  Attended runs ask intent questions, including `style:auto`. Autonomous runs use recorded recommended answers or the supervisor.
- `--no-run`: stop after Step 3. Print the draft path and the exact cycle invocation
  the user would run. (Use when the user wants to eyeball the conversion first.)

## What this skill never does

- Never invents requirements, constraints, or acceptance criteria absent from the source.
- Never answers the source's open questions (SPEC/DISCUSS own resolution; autonomous
  self-answers happen THERE, with the decision record).
- Never resolves intent questions or normalizes format — that is the SPEC
  phase's spec-file ingest mode, already built and gated.
- Never fetches remote content. Supply ticket or thread content as pasted text or a local file, not a URL.
