# Claude Opus 5.5 and Claude Sonnet 5.5, for loop-spec

For a contributor tuning loop-spec's prompts, roles, and model defaults for Claude
Opus 5.5 and Claude Sonnet 5.5. This page says what each model is good at, how it
behaves differently from the models 7.x was tuned on, and what that means for this
plugin. The source pages are copied verbatim from Anthropic's docs into
[anthropic/](anthropic/) (fetched 2026-10-04); each section cites the one it draws on.

| File | Source page |
|---|---|
| [anthropic/opus-5-5-overview.md](anthropic/opus-5-5-overview.md) | Claude Opus 5.5: specs, pricing, comparison table |
| [anthropic/opus-5-5-whats-new.md](anthropic/opus-5-5-whats-new.md) | What's new in Claude Opus 5.5: breaking changes, behavior differences |
| [anthropic/opus-5-5-prompting.md](anthropic/opus-5-5-prompting.md) | Prompting Claude Opus 5.5 |
| [anthropic/sonnet-5-5-overview.md](anthropic/sonnet-5-5-overview.md) | Claude Sonnet 5.5: specs, pricing, comparison table |
| [anthropic/sonnet-5-5-whats-new.md](anthropic/sonnet-5-5-whats-new.md) | What's new in Claude Sonnet 5.5 |
| [anthropic/sonnet-5-5-prompting.md](anthropic/sonnet-5-5-prompting.md) | Prompting Claude Sonnet 5.5 |
| [anthropic/effort.md](anthropic/effort.md) | Effort, with recommended levels per model |
| [anthropic/prompting-best-practices.md](anthropic/prompting-best-practices.md) | Prompting best practices for all current models (agentic systems, subagents, state) |

The API migration guides are not copied: their breaking changes (disabled thinking,
forced `tool_choice`, preserved thinking, the computer-use toolset) concern code that
calls the Messages API directly, which loop-spec does not. Read them online from the
links in each "what's new" page if an example ever calls the API directly.

## At a glance

| | Opus 5.5 (`claude-opus-5-5`) | Sonnet 5.5 (`claude-sonnet-5-5`) |
|---|---|---|
| Built for | long-running agentic coding and knowledge work | speed and capability for everyday coding and agent work |
| Price, input / output per MTok | $4 / $20 | $2 / $10 |
| Context, max output | 1M, 128K | 1M, 128K |
| Thinking | adaptive, always on | adaptive; `between_tools` turns off up-front thinking |
| Default effort | `medium` | `high` (recalibrated from Sonnet 5) |
| Recommended for agentic coding | `medium`; `xhigh`/`max` only where measured | `medium` for well-specified tasks, `high` for harder or longer |

Sources: both overview pages, and [effort.md](anthropic/effort.md) ("Recommended
effort levels for Claude Opus 5.5" and "for Claude Sonnet 5.5").

## Claude Opus 5.5

From [opus-5-5-prompting.md](anthropic/opus-5-5-prompting.md) and
[opus-5-5-whats-new.md](anthropic/opus-5-5-whats-new.md):

- **Agentic coding and review.** Strongest on carrying a change through a real
  repository until its tests pass. At its default `medium` it matched or beat Opus 5
  at `high`, in fewer steps and tokens. It sustains multi-hour autonomous work with
  parallel subagents and little oversight, catches more bugs in review with fewer
  false alarms, and explains its changes in plain language.
- **Reporting.** Its updates while working and its final summary say plainly what it
  did, what it found, and what it needs.
- **Effort is the control.** Thinking cannot be turned off; lower effort before
  prompting for less thinking. It thinks more per turn than Opus 5 at a given level,
  most at `xhigh` and `max`. Remove "think carefully" instructions: the model decides.
- **Early stops in long tasks.** Some progress updates end the turn with text
  instead of a tool call. The fix the docs give: keep the task's parts in a
  checklist the model updates, treat a text-only turn as a report rather than proof
  of completion, and name the kinds of early stop to avoid (the docs' standing
  instruction is the model for the loop-spec skill's "Keep going until the run ends").
- **Multiagent pacing.** It pays close attention to elapsed time; a time budget or
  "time matters" line makes a lead agent parallelize subagents more.
- **Prompt injection.** It resists instructions arriving through tool results better
  than any earlier Opus.

## Claude Sonnet 5.5

From [sonnet-5-5-prompting.md](anthropic/sonnet-5-5-prompting.md) and
[sonnet-5-5-whats-new.md](anthropic/sonnet-5-5-whats-new.md):

- **Agentic coding.** Strongest on multistep coding in a real repository; uses tools
  more reliably and needs no "do not be lazy" or retry shims. For the hardest
  long-horizon work the docs point to an Opus model.
- **Effort changes how it finishes.** At `low` it can report a change done without a
  real check; at `low` and `medium` on long tasks it may stop to check in early. The
  docs give two paragraphs for this: "keep working until everything is done" and a
  verification paragraph (run a real check; a syntax-only check does not count).
- **Scope.** It tends to add tests, docs, and small files the task did not ask for,
  more at higher effort. At `xhigh`/`max` it starts its own review rounds, sometimes
  with reviewer subagents. A "stop and report when done" paragraph curbs both.
- **Literal reading.** It follows tool-discouraging lines ("minimize tool calls")
  literally.
- **Text after tool results.** Harness text that arrives right after a tool result on
  every step can be read as a prompt injection.
- **Tool names.** It occasionally miscases a tool name or a parameter; a clear error
  naming the expected one is enough for it to correct itself.

## What this means for loop-spec

Each point below is a design consequence, with the doc behavior it rests on.

1. **Guidance over gates.** Both models verify their own work at `medium` and up and
   report plainly what they did. Machinery that exists to catch a model faking
   progress (transcript attestation, re-dispatching an unattested judgment, digests
   binding every product to every revision) costs more than the failure it guards
   against now. Keep the checks that observe the world: run the verify commands, and
   deliver the commit that was verified.
2. **Shorter, plainer prompts.** The docs say prompts written for earlier models are
   often too prescriptive. Role prompts should state the goal, the inputs, the output
   shape, and the few rules that are about this program; the models supply the
   engineering judgment.
3. **A DAG the lead drives.** Opus 5.5 orchestrates parallel subagents natively and
   paces itself against a checklist. Give the lead the plan as a task graph it can
   query (ready tasks, done, blocked) and let it dispatch, rather than having the
   program issue every step.
4. **Model and effort defaults.** Lead, planning, and review on Opus 5.5 at `medium`;
   implementers on Sonnet 5.5 at `medium`, `high` for hard tasks. Avoid `low` for
   implementers unless the verification paragraph is in the prompt, and avoid
   `xhigh`/`max` for Sonnet workers unless a self-started review round is wanted.
5. **Keep "Keep going until the run ends" and "Done means checked".** These two paragraphs are
   the docs' own recommended text for both models' known failure modes.
6. **Little text after tool results.** A program line in a Bash result should be data
   (what is ready, what failed), not per-step instructions to the model.
