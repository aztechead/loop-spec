# Ablation plan: which loop-spec components change the outcome

For the maintainer deciding what to keep, and whoever builds and runs these
measurements. This page is a plan: no run described here has been made. It says what
to remove, how, on which tasks, and what result would change the design. It does not
record results; those go into [live-runs-7.0.md](live-runs-7.0.md) once they exist.

## Why

[reliability.md](reliability.md) lists what the program proves: postconditions refuse
an unsupported phase exit, VERIFY re-runs evidence commands in a clean checkout,
EXECUTE compares failure identities against a baseline, commands run with no shell,
state is digested, and DELIVER pushes only the SHA VERIFY passed. Those are
deterministic checks and are not ablated here; removing one would only show that the
failure it prevents then happens.

Four things are unmeasured, because no recorded live run varies them on purpose:

1. Whether loop-spec beats plain Claude Code on the same request. No row in
   [live-runs-7.0.md](live-runs-7.0.md) gives one request to `claude -p` with no
   plugin and to loop-spec.
2. Whether [`roles/principles.md`](../../skills/loop-spec/roles/principles.md) changes
   outcomes. `roles.principles()` appends it to every role prompt whatever skill is
   bound ([roles.py](../../skills/loop-spec/program/loop_spec/roles.py)), and
   [runner.md](../../skills/loop-spec/references/runner.md) tells the lead to read it.
3. Whether the plan-critic, the ITERATE judge, and the code-reviewer earn their cost.
4. Whether the planner's "Engineering principles" section does anything.

### What the existing natural experiments show

Two comparisons exist, and neither supports a conclusion.

- `fp-trap` (7.6.2 without the first-principles stance, 7.7.0 with it): the same
  behavior on both. The debugger's own reproduce-first method already refutes the
  report, so the pair cannot show the stance. n=1 per side.
- `td-772` and `td-773` (the Fahrenheit figure -459.67 offered as absolute zero in
  Celsius): 7.7.2 kept the wrong limit through 14 role steps and 10 transitions, 423 s,
  46 turns, $3.44. 7.7.3 flagged the premise at the router step and corrected it to
  -273.15 C in 9 role steps and 7 transitions, 266 s, 33 turns, $2.17. `git diff
  --stat 319dd4f 9a5128f` shows the commits differ in one behavior file,
  `roles/principles.md` (+46 lines, the thinking discipline), plus version strings,
  the CHANGELOG, and two docs lines. So the pair is cleaner than a two-version
  comparison usually is. It is still n=1 per arm, the added text is a bundle of about
  ten paragraphs (so it cannot say which one mattered), and a single run can flag a
  premise by chance.

[evals/README.md](../../evals/README.md) already learned that two runs per query
cannot rank two variants, and its default is now 5. This plan starts from 5 per task
per arm and says below what that can and cannot resolve.

## Questions, with a prior guess for each

The guesses are the author's, written before any run, and are there so a result can
surprise us. They are not findings.

| Arm comparison | Question, stated so a result can falsify it | Prior guess |
|---|---|---|
| A0 vs A1, A0 vs A2 | Does loop-spec pass the hidden oracle on more of the 45 runs than plain `claude -p` on the same requests? Falsified if neither A1 nor A2 passes more runs than A0 by the resolvable margin, 6 to 9 of 45 depending on the base rate (see [Sample size](#sample-size-and-what-it-can-resolve)). | `micro` beats A0 on tasks that have tests, mostly on the premise tasks and the one where a naive change breaks a test. On the easy tasks A0 also passes, so the pass-rate gap is small and the cost gap is large. |
| A2 vs A1 | Does the full cycle pass more runs than `micro`, enough to pay for the extra phases? Falsified if A2 does not pass more by the resolvable margin, or costs more than twice A1 per pass. | No difference on these small tasks. |
| A2 vs A2 without `principles.md` | Does removing the first-principles preamble lower the pass rate or the premise-flag rate? Falsified if neither falls. | No measurable effect on the pass rate. The premise-flag rate on the wrong-premise and false-premise tasks may fall, as `td-773` suggests. |
| A2 vs A2 without the plan-critic | Does removing the critic lower the pass rate, or raise rewinds and cost? Falsified if none moves. | No measurable effect. The critic's Critical-only rule makes it fire rarely, and it fires mostly on verify-command defects the program's baseline also catches. |
| A2 vs A2 without ITERATE's judge | Does removing the judge lower the pass rate on tasks where the request and the spec can diverge? Falsified if not. | No measurable effect on these fixtures; the wrong-premise task is the one place it could matter. |
| A2 vs A2 without the planner's "Engineering principles" section | Does removing the section change the plan or the oracle result? Falsified if not. | No measurable effect. `existingCode` (planner procedure step 7) already asks for the reuse search the "laziness ladder" bullet describes. |
| (optional) A2 vs A2 without code review | Does removing both reviews lower the pass rate? | Lowers it a little, mostly on the task where a naive change breaks a test. |

The author's overall guess: the deterministic program layer earns its place (not
tested here); `micro` beats plain Claude Code on tasks with tests; and at least one of
the critic, ITERATE, and the principles prose shows no measurable effect.

## Arms

Every arm: Claude Code at one pinned version, the lead and every role worker on
Sonnet, the same task set, the same flags. Only the listed difference changes.

| Arm | Runs | Difference from the one above it |
|---|---|---|
| A0 | `claude -p "<request>"`, no plugin | baseline: plain Claude Code |
| A1 | `/loop-spec:micro <request> [Operator: ...]` | loop-spec, compact presets |
| A2 | `/loop-spec:cycle <request> [Operator: ...]` | full cycle |
| A2-nop | A2 with `principles.md` emptied | no first-principles preamble |
| A2-nocrit | A2 with the plan-critic bound to a stub | no plan-critic judgment |
| A2-noiter | A2 with the iterate-judge bound to a stub | no ITERATE judgment |
| A2-noplan | A2 with the planner's "Engineering principles" section deleted | no planner principles |
| A2-norev (optional) | A2 with the code-reviewer bound to a stub | no code review |
| A2-p772 (optional) | A2 with `principles.md` as of `319dd4f` | stance without the 7.7.3 thinking discipline |

Both A1 and A2 force the entry. The `auto` router, `debug`, and `revise` are not
covered, so the bug and false-premise tasks measure `cycle` and `micro`, not the entry
a user would be routed to. `micro` still runs all six phases with compact presets
([phase-interface-7.0.md](phase-interface-7.0.md#entry-points-and-the-order): "cannot
drop a required phase"), so A1 includes the critic and the ITERATE judge too.

### How each component is removed

Use the least invasive supported mechanism, and a plugin worktree only where no
configuration exists. Each stub is a project skill the program inlines into the role's
step prompt ([README](../../README.md#use-your-own-skill-or-plugin-in-a-phase),
[contract.md](../../skills/loop-spec/references/contract.md#implementations)).

| Arm | Mechanism | Left in place | What the arm cannot isolate |
|---|---|---|---|
| A2-nocrit | `.loop-spec/config.json`: `{"roles": {"plan-critic": "ablate-plan-critic"}}` and a stub skill `.claude/skills/ablate-plan-critic/SKILL.md` whose body says to write `{"findings": []}` to the result path and read nothing else | the step is still dispatched, attested, and validated against the critic schema; P7 ("the critic pass ran") is met; first principles and `contract.md` are still appended | the critic's cost is not fully removed: one worker step still runs. The arm removes the critic's reading and reasoning, not its dispatch. |
| A2-noiter | the same, `{"roles": {"iterate-judge": "ablate-iterate-judge"}}`, stub body writes `{"verdict": "met", "gaps": [], "caveats": []}` | the program still reconciles a `met` verdict against open ledger findings (`iterate.py`, "A `met` verdict over an open ledger finding is not met") | same: a step is still dispatched. |
| A2-norev (optional) | `{"roles": {"code-reviewer": "ablate-code-reviewer"}}` | | A bound code-reviewer applies in both EXECUTE and VERIFY ([README](../../README.md#use-your-own-skill-or-plugin-in-a-phase): "configuring it changes both"), so a per-task-only removal is not possible by configuration. The stub must return `sha`, `reviewedRange`, `verdict: "pass"`, `findings: []` and one `securityDispositions` entry per probe `securitySignals` entry, copied from the inputs (`inputs.range` in a single-task review), and a wave review (`execute.py`, `_wave_schema`) needs one result object per task. VERIFY's input keys were not read for this plan; read `verify.py` before writing the stub. This is the arm most likely to need a pilot fix. |
| A2-nop | a plugin worktree (below) with `skills/loop-spec/roles/principles.md` truncated to an empty file, and the "## Reasoning" section of `skills/loop-spec/references/runner.md` deleted | the file still exists, so the lead's read succeeds; prompts carry an empty `## First principles` heading | no configuration reaches `principles()`; it reads the file under `ROLES_DIR` whatever skill is bound. Deleting the runner.md section too matters: without it, the lead is told to apply a file that is empty, which is a different arm. The unit tests `test_roles` and `test_entries` assert the stance is present, so the worktree's tests fail by design; do not run them there. |
| A2-noplan | a plugin worktree with the `## Engineering principles` section of `skills/loop-spec/roles/planner/SKILL.md` deleted (the lines from that heading to the line before `## What NOT to do`) | the planner procedure, including the `existingCode` search (step 7) and the changelog task (step 4) | not a configuration: binding `roles.planner` to a stub replaces the whole method, which removes far more than the section. |
| A2-p772 (optional) | a plugin worktree with `git show 319dd4f:skills/loop-spec/roles/principles.md` as `principles.md`, and runner.md unchanged | | |

Two facts that shape the arms:

- The section heading "Engineering principles" appears in seven role files
  (`planner`, `implementer`, `code-reviewer`, `verifier`, `spec-writer`, `debugger`
  and `reviser`; a `grep` finds it in each). A2-noplan removes only the planner's. The
  "laziness ladder" bullet also lives in `implementer` and `reviser`, so a
  planner-only removal leaves the idea with the implementer. A null result means "the
  planner's copy adds nothing", not "the idea adds nothing".
- Several of the planner section's bullets have no task here that exercises them: the
  fixtures have no `CLAUDE.md` or `CONTRIBUTING`, no third-party dependency, and no
  component or store for "design for scale". The tasks that can exercise the section
  are `feat-multi` (docs the change reaches, house style) and `reuse` (the laziness
  ladder).

### Evidence for the stub arms

Judgment roles need host-attested evidence. The family comes from the bundled role's
own SKILL.md frontmatter, `evidence: judgment`, read by `contract.role_meta` "whatever
skill a project binds in its place"; a bound stub does not change it. So the stubbed
critic and judge still go through attestation: the transcript must open with the
dispatched prompt and end with the result digest
([reliability.md](reliability.md#evidence-levels)). A stub that writes a fixed result
should attest like any other step, and nothing in the arm needs
`evidence.judgment.accept: "unattested"`. Do not set it: it would add a
`weakenedAssurance` entry the other arms lack. If a stub step fails attestation in the
pilot, record that and fix the stub text; fall back to the opt-in only as a deliberate,
recorded departure for that arm. I have not run a stubbed step, so this is from
reading `steps.py`, not from observation.

### Isolation and pinning

- **Plugin commit.** Pin one commit of this repository for all arms, chosen when the
  work starts (the checkout at the time of writing is 7.9.0). Record the full SHA in
  every run row.
- **One worktree per file-changing arm.** CLAUDE.md forbids editing `skills/` in a
  checkout a live run is reading. Create `git worktree add --detach <dir> <pinned>`
  once for the pristine copy, which A1, A2, A2-nocrit, A2-noiter and A2-norev all load
  with `--plugin-dir` and never edit, and one more for each of A2-nop, A2-noplan and
  A2-p772 with its edit left uncommitted. Save each worktree's `git diff` with the
  results; a reviewer should see that it changes only the intended lines. The
  launcher is called relative to the stub's own directory
  (`${CLAUDE_SKILL_DIR}/../loop-spec/program/loop-spec`), so a run reads the program
  from the worktree it was loaded from.
- **No other loop-spec.** The session must not also load an installed loop-spec. Run
  with a Claude Code config directory that has no plugins installed, and check the
  stream-json `init` message's plugin list (the `h776-c` row read it to confirm which
  plugins loaded). I did not verify how a `--plugin-dir` copy and an installed copy of
  the same name resolve against each other.
- **Config and stubs live in the fixture clone, untracked and excluded.** Write
  `.loop-spec/config.json` and `.claude/skills/ablate-*/SKILL.md` into the clone's
  working tree, and add `.claude/` to the clone's `.git/info/exclude` (the program
  excludes `.loop-spec/` itself). `roles.load_role` reads them from the project root,
  not from a worktree. Not verified live: that no start-up check minds an untracked,
  excluded `.claude/`. The pilot confirms it.
- **State.** Every run sets its own `LOOP_SPEC_HOME`, in the run's temp directory, so
  no run sees another's state. Every run gets a fresh fixture and a fresh bare
  `origin`.

## Model

All arms run `claude -p --model sonnet`, and every role worker is pinned to Sonnet, so
model choice is not a variable. The defaults put the judgment roles (`router`,
`plan-critic`, `code-reviewer`, `iterate-judge`) on Opus and the implementation roles
(`implementer`, `verifier`, `resolver`) on Sonnet
([README](../../README.md#configuration)); this plan overrides that on purpose, for
the judgment roles, with the environment variables `LOOP_SPEC_MODEL_PLAN_CRITIC`,
`LOOP_SPEC_MODEL_CODE_REVIEWER`, `LOOP_SPEC_MODEL_ITERATE_JUDGE` and
`LOOP_SPEC_MODEL_ROUTER` set to `sonnet` (environment takes precedence over config).
Set the three Sonnet-default roles the same way, so the arms stay pinned if a default
changes.

Consequences to keep in view:

- The result says how the components behave with a Sonnet critic and judge. The shipped
  default is Opus for those roles, which may catch more. A positive result for a
  component on Sonnet does not prove it on Opus, and a null result does not either.
- `sonnet` is an alias. Live-runs records that the alias served `claude-sonnet-5` on
  Claude Code 2.1.284, and that `claude-sonnet-5-5` answers under its full ID but the
  Agent tool's `model` field does not accept it. So the lead and the workers may not be
  the same model snapshot. Record the model id from each transcript (the
  `v76-auto` row did) and stop the study if it changes midway.
- Effort is left at each role's default (`medium` for workers, per
  `loop-spec:worker-medium`) and at the session default for the lead, identical in
  every arm. Record the Claude Code version, which every arm shares; disable
  auto-update for the study (how is a Claude Code setting this repository does not
  document, so check it).

## Task set

Nine tasks, each a small stdlib-only Python repository with a `unittest` suite, so no
install step runs (the `h776-d` row records that `python3` on the maintainer's
machine has no pytest). Every request names its verify command as one plain argv, as
the README advises: `python3 -m unittest discover -s tests`. Fixtures are modeled on
the ones in [live-runs-7.0.md](live-runs-7.0.md) (`calc`, `tempconv`, a `negate`
fixture for `fp-trap`) and on the `FIXTURE` dict in
[route_eval.py](../../evals/route_eval.py). The hidden oracle for each task is a test
module kept outside the fixture and never shown to the agent; the harness runs it
after the arm finishes. Oracles import only the package and the standard library.

A run's graded tree is: for the loop-spec arms, the head of the feature branch DELIVER
pushed to the local bare `origin` (a fresh clone of it); for A0, the fixture's working
tree after the process exits, uncommitted edits included. When a loop-spec run pushed
nothing, the graded tree is the base commit.

| Id | Kind | Fixture (base files) | Request (verbatim) | Hidden oracle | Passes when |
|---|---|---|---|---|---|
| `feat-one` | one-file feature | `calc`: `calc/__init__.py` with `add`, `sub`; `tests/test_calc.py` testing both | "Add `clamp(x, lo, hi)` to `calc/__init__.py`. It returns x limited to the range lo to hi inclusive and raises ValueError when lo is greater than hi. Add tests in `tests/test_calc.py`. Verify with `python3 -m unittest discover -s tests`." | `clamp(5,0,3)==3`, `clamp(-1,0,3)==0`, `clamp(2,0,3)==2`, `clamp(0,0,0)==0`, floats, a negative range, ValueError for `lo>hi`; existing `add` and `sub` tests still pass | oracle passes |
| `feat-multi` | multi-file feature | `wordtally`: `wordtally/counts.py` (`count_words`), `wordtally/cli.py` (`main(argv)` prints every `word count` alphabetically), `README.md` documenting usage, `tests/test_counts.py`, `tests/test_cli.py` | "Add a `--top N` option to the `wordtally` command that prints only the N most frequent words, one `word count` per line, ties broken alphabetically. N below 1 must exit with status 2 and a message on stderr. Counting belongs in `wordtally/counts.py`, argument parsing in `wordtally/cli.py`. Add tests and document the option in `README.md`. Verify with `python3 -m unittest discover -s tests`." | run `python3 -m wordtally.cli --top 2 sample.txt` against a sample with ties and compare lines exactly; `--top 0` and `--top -3` exit 2 with non-empty stderr; no option leaves the old output unchanged; `README.md` contains `--top` | oracle passes |
| `bug-test` | bug with a failing test | `pager`: `pager/paginate.py` with `paginate(items, page, per_page)` using floor division for the page count, so a last partial page returns `[]`; `tests/test_paginate.py` with passing tests (including `page < 1` raising ValueError) and a failing `test_last_partial_page` | "`tests/test_paginate.py::test_last_partial_page` fails: `paginate(list(range(5)), page=3, per_page=2)` returns `[]` and should return `[4]`. Fix it. Verify with `python3 -m unittest discover -s tests`." | partial last page for several sizes, `per_page` larger than the list, an exact multiple, an empty list, page past the end returns `[]`, `page < 1` still raises ValueError | oracle passes |
| `false-premise` | the bug does not exist (as `fp-trap`) | `signs`: `signs/ops.py` with a correct `negate(x)` and `absolute(x)`; passing tests | "`negate` returns the wrong sign for negative inputs. Fix it and add a regression test. Verify with `python3 -m unittest discover -s tests`." | `negate(-3)==3`, `negate(3)==-3`, `negate(0)==0`, floats; `signs/ops.py` byte-identical to base | oracle passes, source unchanged, and the final message says the report is wrong (pattern below) |
| `wrong-premise` | the request states a wrong fact (as `td-*`) | `tempconv`: `tempconv/__init__.py` with `c_to_f`, `f_to_c`; passing tests | "Add `c_to_k(c)` to `tempconv/__init__.py`, returning kelvin and raising ValueError for any input below absolute zero (-459.67 C). Add tests. Verify with `python3 -m unittest discover -s tests`." | `c_to_k(0)` is `273.15` (to 6 places), `c_to_k(-273.15)` is `0`, `c_to_k(-273.16)`, `c_to_k(-300)` and `c_to_k(-400)` raise ValueError; no input returns a negative kelvin | oracle passes (the limit must be -273.15 C) |
| `satisfied` | already done | `strkit`: `strkit/case.py` already defines `title_case(s)` (first letter of each space-separated word upper, rest lower), with tests in `tests/test_case.py` | "Add `title_case(s)` to `strkit/case.py`: capitalize the first letter of each space-separated word and lowercase the rest. Add tests. Verify with `python3 -m unittest discover -s tests`." | `title_case("hello wORLD")`, empty string, single letter, extra spaces kept; `strkit/case.py` byte-identical to base | oracle passes, source unchanged, and the final message says it already exists |
| `naive-breaks` | a naive change breaks an existing test | `shop`: `shop/money.py` with `to_cents(s)` returning `0` for a blank string; `shop/cart.py`; `shop/report.py` whose `load_totals(rows)` calls `to_cents` on blank cells; `tests/test_money.py` (including `to_cents("") == 0`), `tests/test_report.py` (including `test_blank_cells_count_as_zero`) | "`to_cents('')` should raise ValueError instead of returning 0. Update the tests that check the old behavior. Verify with `python3 -m unittest discover -s tests`." | `to_cents("")` and `to_cents("  ")` raise ValueError, `to_cents("12.50")==1250`; `report.load_totals` with a blank cell still counts it as 0; `tests/test_report.py` byte-identical to base | oracle passes (changing only `to_cents` breaks the report test; the fix is to handle blank cells in `report.py`) |
| `reuse` | an existing helper should be reused | `blog`: `blog/text.py` with `slugify(title)` (strips accents, collapses dashes), `blog/posts.py` with a `Post` having `id` and `title`; tests for `slugify` | "Add `post_url(post)` to `blog/posts.py` returning `/posts/<slug>-<id>`, where the slug comes from the post's title. Add tests. Verify with `python3 -m unittest discover -s tests`." | `post_url(Post(7, "Café Ünï"))` equals `"/posts/" + slugify("Café Ünï") + "-7"`; with `blog.text.slugify` patched to return `"S"` (and `blog.posts.slugify` patched too, `create=True`), `post_url` returns `"/posts/S-7"`, so a private copy of the slug logic fails | oracle passes |
| `missing-symbol` | the named code does not exist (as `fp-div`) | `mathx`: `mathx/__init__.py` with `add` and `mul` only; passing tests | "Update the docstring of `divide` in `mathx/__init__.py` to say it raises ZeroDivisionError when the divisor is 0. Verify with `python3 -m unittest discover -s tests`." | `mathx/__init__.py` has no `divide` (checked with `ast`) and is byte-identical to base | oracle passes, source unchanged, and the final message says `divide` does not exist |

Three tasks expect no source change (`false-premise`, `satisfied`, `missing-symbol`). A
run that crashes before touching anything would pass a "source unchanged" check by
accident, so for those three the primary pass also requires the premise flag. The flag
is a case-insensitive regular expression per task, written into the task file before
any measured run. Illustrations only, to be frozen with the tasks: `false-premise`
matches `already correct|correct sign|not reproduc|cannot reproduce|no bug`;
`satisfied` matches `already (exists?|defined|implemented|present)`; `missing-symbol`
matches `divide.{0,40}(does not exist|not defined|no such|missing|not found)`. The final message is
the last assistant message of the stream, or, for a loop-spec run that ended on a
question, the question text. Read a random 20% of the flag decisions by hand and
report the disagreement rate. The `wrong-premise` task's flag is secondary only, since
its oracle already needs the correct limit.

Choose and freeze the task files, oracles and patterns before the first measured run.
Do not drop or rewrite a task after seeing results. If A0 passes nearly every task, say
so: the tasks were too easy to show an effect on the oracle, and the evidence is then
the secondary metrics. Harder tasks are a new, separately frozen set, not an edit.

## Scoring

Per run, recorded by the harness:

| Metric | Source |
|---|---|
| **Primary: oracle pass/fail on the final head** | the hidden test module, plus the no-change and premise-flag conditions in the table above |
| Premise flagged (yes/no) | the per-task pattern over the final message |
| Cost in USD, wall time, turns | the stream-json final `result` event (`total_cost_usd`, `duration_ms`, `num_turns`; the same fields the SDK's `ResultMessage` carries, see `sdk_runner.py`). Not read from a live stream in this repository; check against one real stream in the pilot |
| Role steps | count of `step_issued` events in the run's `events.jsonl`; the event carries only the step id, so the per-role counts come from each step's `step.json` under the state home ([contract.md](../../skills/loop-spec/references/contract.md#state-home-layout)) |
| Transitions and rewinds | `transition` events in `events.jsonl`; `rewinds` and `iterations.used` in `result.json` (both are the length of the budget's transition list) |
| Result value | `result.json`: `result`, `status`, `phaseReached`, `verification`, `weakenedAssurance`, `noChangeReason`, `hostVersions` ([contract.md](../../skills/loop-spec/references/contract.md#result)) |
| Served model | the transcript's model id per step |

Every loop-spec run uses `--answer-policy default` and a local bare `origin`, as the
`td-*`, `c772-*` and `e774-*` runs did. With no GitHub host, DELIVER pushes and then
stops, and the run ends `escalated` at DELIVER with verification passed; that is what
a good run looks like in those rows. **DELIVER is not scored**, and `escalated at
DELIVER` is not a failure for scoring. A run that stops on a question the policy
cannot answer, or ends with no `result.json`, scores by the oracle on whatever was
pushed, which is nothing, and the harness records `no-result` and the question text so
the cause can be read. Such a run counts as a failure; when interpreting, separate
program defects from model behavior by reading the cause.

Run order is shuffled across arms and tasks with a recorded seed, so a model or
service change midway does not line up with one arm.

## Sample size and what it can resolve

Five runs per task per arm: 45 per arm.

Treat the 45 runs of an arm as one pass count, and treat the tasks as the unit when
the arms differ on only some of them. The results are clustered by task (a task is
easy or hard for every arm), so the 45 are not 45 independent draws.

What 45 against 45 can resolve, from a normal-approximation power calculation and an
exact test I ran while writing this plan:

- At a base pass rate near 90%, a drop to about 65% (43 runs per arm) is detectable
  with 80% power. A drop to 75% needs about 100 per arm, and to 80% about 200.
- Concretely, an arm that passes 45 of 45 is separable from one that passes 39 or
  fewer; 42 from 34; 40 from 31 (Fisher exact, p < 0.05). A difference of 5 or fewer
  passes is not distinguishable from noise.
- If a removal arm passes the same 40 of 45 as A2, the 95% interval on the difference
  is about plus or minus 14 points. A true 10-point loss (90% to 80%) would show "no
  more than one fewer pass" about one time in five.

So this design finds large effects and cannot show a component is harmless. "No
measurable effect at n=45" means a loss of more than about 13 to 20 points is
unlikely, not that none exists. Cost, wall time and turn counts are continuous and
skewed (live runs range from $0.14 to $12.28 on one run); compare medians with a
bootstrap interval, and expect cost differences to be resolvable well before pass-rate
differences are. Runs within an arm vary for reasons unrelated to the arm: the
`sonnet` alias, the model's own variation, and the program defects the live-runs table
records on earlier commits (a run can fail on a bug in the pinned commit, which counts
against loop-spec honestly but should be labelled, not hidden).

## Decision rule, fixed before the runs

Adopt these before the first measured run and do not adjust them to a result.

- **The test.** Two arms differ when Fisher's exact test on their 45-run pass counts
  gives p < 0.05. Near the ceiling that takes 6 passes (45 against 39), near 40 of 45
  it takes 9. The three no-change tasks and `wrong-premise` also compare premise-flag
  rates. Report the per-task counts beside the pooled one, since a gap carried by one
  task is a task result.
- **Loop-spec versus A0.** An arm "beats" A0 when the test says it passes more and its
  premise-flag rate is not lower; it "loses" when the test says it passes fewer.
  Otherwise the result is "not distinguishable on these tasks", and the cost ratio is
  the finding.
- **A component is a deletion candidate** when its removal arm loses no more than one
  oracle pass against A2 over the 45 runs, loses no task by 2 or more of 5, does not
  lower the premise-flag rate, and costs at least 10% less per run at the median. A
  component with any cost and no measured effect is a candidate for deletion, not proof
  of uselessness: the next step is a larger run on the tasks that exercise it, not
  deletion.
- **A component is kept** when its removal arm passes fewer than A2 by the test above
  (or loses 3 or more of 5 on one task that can exercise it, with the others
  unchanged and a rerun of that task reproducing it), or when its removal raises
  rewinds or cost enough to offset what the component costs.
- **Unexercised is not useless.** For each component, report on how many A2 runs its
  trigger fired: the critic recorded a Critical finding, the ITERATE verdict was
  `unmet`, a rewind occurred. A component that never fires on these fixtures has no
  result here at all, only a statement that these tasks do not reach it.
- **Planner-section and principles arms read the secondary metrics too.** Their effect,
  if any, is on the plan and on premise handling, which may show in rewinds and role
  steps before it shows in the pass rate.

## Budget

Recorded costs, recomputed from [live-runs-7.0.md](live-runs-7.0.md) for this plan:
about 64 per-run or per-session cost figures (a few cover two sessions together, such
as `ea-b` and the `t790-2` pair), summing to about $225 and with a median of about
$2.8; the largest are $12.28 (`t790-9`) and "about $20" for the whole `t790-10`
session. The $19.30 and $16.15 figures in that page are totals of four runs each, not
single runs. The cheapest comparable rows are $1.5 to $2.5 for a small feature on
Sonnet (`c772-tempconv` $2.03, `td-773` $2.17).

Planning figures per run (guesses except where a row is cited): A0 $0.5, with no
recorded plain-Claude cost in this repository; A1 $2.5, since the recorded `micro`
rows with a cost run $2.4 to $4.8, mostly on a PR-adopting or Opus-led setup, so a
small Sonnet-only run should sit at the low end; every cycle arm $2.8, the recorded
median. Stub arms will cost a little less than A2 and are not discounted here.

| Stage | Runs | Estimated cost |
|---|---|---|
| Pilot: one run of each arm on `feat-one`, plus A0 and A2 on `wrong-premise` | about 11 | about $25 |
| A0, A1, A2 on all nine tasks, 5 runs each | 135 | about $260 |
| Full design: A2-nop, A2-nocrit, A2-noiter, A2-noplan on all nine tasks, 5 runs | +180 | about $505 |
| Optional: A2-norev, A2-p772 | +90 | about $250 |
| Full design total, optional arms excluded | 315 | about $765 |
| Full design total with both optional arms | 405 | about $1,020 |

Add 10 to 15% for runs repeated after a harness failure. The full design is about
three to four times everything recorded in live-runs-7.0.md so far. Wall time per run
is 4 to 35 minutes in the recorded rows; at four runs in parallel, 315 runs is about
ten hours of waiting.

### Cheaper first pass

1. **Pilot (about $25).** One run of every arm on `feat-one`, and A0 and A2 on
   `wrong-premise`. Purpose: the stubs attest, the worktrees load only the intended
   plugin, no start-up check objects to the untracked `.claude/`, the stream-json
   fields exist, and the oracles pass on a hand-written correct solution and fail on
   the base. Fix the harness, not the arms, from what it shows. Pilot runs are not
   measured runs.
2. **A0, A1, A2 on all nine tasks (about $260).** Answers the first two questions and
   shows which tasks differ between plain and loop-spec. If A0 passes about every
   task, stop and write harder tasks before spending on component removals.
3. **Removals only where they can show an effect (about $225).** Run each removal arm
   only on the tasks where its trigger fired in at least one of A2's five runs (the
   critic recorded a Critical; the ITERATE verdict was `unmet`; a rewind happened), plus,
   for A2-nop and A2-noplan, the tasks where A2 and A0 differed on the oracle or the
   premise flag. About four tasks by four arms by five runs is 80 runs. A removal arm
   with no triggered tasks is reported as "not exercised", not run.

The staged total is about $510 against about $765 for the full design, and the
second stage can be stopped early.

## Harness

Add `evals/ablation_eval.py`, in the style of [route_eval.py](../../evals/route_eval.py).
It is not written yet; this is its interface.

- **Language and style.** Python 3 standard library only, `logging` and never `print`
  (`tests/test_log.py` fails on any `print` call in shipped code and `examples/`; the
  evals follow the same rule), a `ThreadPoolExecutor` over runs, the `CLAUDECODE`
  variable removed from the child's environment as `route_eval.py` does.
- **Inputs.**
  - `--tasks evals/ablation/tasks.json`: per task its id, fixture files (path to
    content), request text, `expects` (`change` or `no-change`), the hidden oracle's
    path (kept under `evals/ablation/oracles/`, never copied into a fixture), and the
    premise-flag pattern.
  - `--arms evals/ablation/arms.json`: per arm its id, entry (`none`, `micro`,
    `cycle`), plugin directory, fixture overlay files (config and stubs), and extra
    environment (`LOOP_SPEC_MODEL_*`).
  - `--runs` (default 5), `--model` (default `sonnet`), `--workers`, `--timeout`
    (default 3000 s, above the longest recorded run), `--seed`, `--only-arm`,
    `--only-task`, `--out`.
- **One run.** In a temp directory: build the fixture and `git init`, make a bare
  `origin`, add it, push `main`; write the arm's overlay and the `.git/info/exclude`
  line; set `LOOP_SPEC_HOME` to a directory inside the temp tree; spawn `claude -p`
  with the request (the loop-spec arms prefixed with `/loop-spec:<entry>` and followed
  by the operator note that asks for `--answer-policy default`, as the README's
  headless example does; A0 gets the bare request) and `--model`, `--plugin-dir` (not
  for A0), `--permission-mode`, `--output-format stream-json --verbose`; read the
  stream to the end. The permission mode is the README's headless example,
  `bypassPermissions`, inside throwaway directories. Recent live-runs rows used
  `auto`, which has a host classifier that denied edits in the `t790-6` row. I did not
  verify that host attestation works under `bypassPermissions` on the pinned Claude
  Code; the pilot decides, and the mode must be the same in every arm.
- **After exit.** Parse the stream for the `init` message (version, plugins, model),
  the final `result` event, and the last assistant text. For a loop-spec arm read the
  run's `result.json` and `events.jsonl` under `LOOP_SPEC_HOME`. Build the graded tree
  as defined under [Task set](#task-set), run the oracle against it with a timeout, and
  evaluate the no-change and flag conditions.
- **Outputs.** One JSON line per run (arm, task, run index, seed, pinned commit,
  Claude Code version, served model ids, oracle pass, premise flag, `no-result` and why,
  cost, wall time, turns, role steps by role, transitions, `result` value, session id),
  the raw stream and `events.jsonl` kept per run under `--out`, and a summary: pass
  counts by arm and by arm-by-task, premise-flag rates, cost medians with a bootstrap
  interval, and the paired per-task comparison between each removal arm and A2.
- **Recording.** One row per arm in [live-runs-7.0.md](live-runs-7.0.md)'s format
  (Case, Run tag, Result, Notes), with tags such as `abl-a2-nocrit-<task>-<n>` kept in
  the notes, the pooled and per-task pass counts, the pinned commit and Claude Code
  version. Nine tasks by nine arms by five runs is too many rows
  for the table, so write per-arm rows with per-task counts in the notes, and keep the
  per-run files in the results directory rather than the repository unless a row needs one.
- **No fake runner.** The harness drives the real `claude` binary and the real model.
  Nothing here simulates a cycle or adds an offline cycle test, per CLAUDE.md.

## What would change the design

| Outcome | Change |
|---|---|
| A1 and A2 both beat A0 on the oracle by the threshold | Keep the program. Look at which tasks carry the gap; if it is the premise and naive-change tasks, the value is in checking, and the entry text should say so. |
| A0 matches or beats loop-spec on the oracle at far lower cost | What loop-spec adds on these tasks is the delivery and evidence guarantees, not correctness. Say that in the README, and tell users to run small, well-tested changes in a plain session; consider narrowing what `micro` is for. |
| A2 no better than A1 | Collapse toward `micro` for small and medium work; `cycle` stays for the work that needs its approvals and its larger plans. |
| A2-nop loses passes or premise flags | Keep `principles.md`; consider shortening it by testing paragraphs against A2-p772. |
| A2-nop shows nothing, and A2-p772 shows nothing | The preamble is a deletion candidate. Weigh the prompt tokens it adds to every step (it is on every role prompt and read once by the lead) against the single `td` pair; rerun on more wrong-premise tasks first, since that is where it showed an effect. |
| A2-nop shows nothing but A2-p772 differs from A2 | The 7.7.3 thinking discipline is the part doing work, or hurting; test its paragraphs one at a time. |
| A2-nocrit loses nothing and costs less | The critic is a deletion candidate in its current Critical-only form; keep the baseline-fact checks that P-rules already enforce. If it never fired, the tasks did not reach it and the result is empty. |
| A2-nocrit loses on `satisfied` or `naive-breaks` | Keep the critic; the already-satisfied and uncovered-criterion rules in its method are the ones paying for it. |
| A2-noiter loses nothing and costs less | The judge is a deletion candidate; the program's own ledger reconciliation of `met` over open findings stays either way. |
| A2-noiter loses on `wrong-premise` or a spec-drift task | Keep the judge. |
| A2-noplan shows nothing | The planner section is a deletion candidate; the `existingCode` step in the procedure and the implementer's copy of the ladder cover the idea. |
| A2-norev loses passes | Keep the reviews. If it loses none, test on a task set designed to be hard to review (security, concurrency) before drawing anything. |
| Any arm's runs fail on the stub or the worktree, not on the component | Fix the arm and rerun it; do not count it. |

## Checked, and not checked

Checked against the files cited above: that `principles()` reads `roles/principles.md`
whatever skill is bound; that `runner.md` tells the lead to read it; that a bound
role's `evidence` family comes from the bundled role's frontmatter; that
`roles.<role>` accepts a binding string or an object and that the environment
variables take precedence; that a bound code-reviewer applies in both EXECUTE and
VERIFY; that `micro` runs all six phases; that the planner section and its bullets
are as quoted; that only `roles/principles.md` differs in behavior between `319dd4f`
and `9a5128f`; and the cost figures recomputed from the live-runs page.

Not verified, and to be settled in the pilot:

- that a stubbed critic, judge, or reviewer attests and passes its schema and the
  program's review checks (read from `steps.py`, never run);
- that an untracked, excluded `.claude/` and `.loop-spec/config.json` in the project
  root trip no check;
- that host attestation works under the permission mode chosen, on the pinned Claude
  Code version;
- how a `--plugin-dir` copy and an installed copy of the same plugin name resolve;
- the stream-json field names for cost, turns and duration (inferred from the SDK's
  `ResultMessage` in `sdk_runner.py`);
- plain Claude Code's cost on these tasks (no recorded figure);
- VERIFY's reviewer input keys, needed for the optional code-review stub;
- how to pin Claude Code's version and disable its auto-update.
