# loop-spec Contributor Guidelines

For a contributor changing this repository. Each bullet names a moment you can
recognize while working and what to do; a rule with no trigger does not fire.

- **When you would add a dependency to the shipped program**, don't. Runtime is
  `bash` (the one-line launcher only), `git`, and `python3` >= 3.11, stdlib only.
  Shipped code lives under `skills/loop-spec/program/loop_spec/`: one module, one
  reason to change (`runs.py` owns a run's files and `state.json`, `dag.py` only
  answers questions about the task graph, `git.py` makes every git and gh call); the
  table in [docs/architecture.md](docs/architecture.md) lists them. `examples/` holds
  a reference consumer that may import the SDK it demonstrates and says in its own
  README that it is not a supported surface.
- **When you would write output or a log line** in shipped code or `examples/`, use
  the `logging` module, never `print`: in `loop_spec`, `log.stdout` for what a caller
  reads (status lines, `LOOP_SPEC_*` markers) and `log.stderr` for diagnostics.
  `tests/test_log.py` fails on any `print` call.
- **When you would write an offline test for a whole cycle**, don't. Unit tests
  (`skills/loop-spec/program/tests/`, `python3 -m unittest discover -s tests`) cover
  the program's deterministic Python only: the task graph, run state, and git flows
  against throwaway repositories. There is no fake model and no offline cycle suite.
  Model-driven behavior is shown by a live run, recorded locally outside the
  repository, never simulated.
- **When you change a program command, its output, or the shape of `spec.json` or
  `plan.json`**, update [skills/loop-spec/SKILL.md](skills/loop-spec/SKILL.md) or the
  reference that covers it in the same diff: they are the lead's only description of
  them.
- **When you would add a gate** (the program refusing something), check that it
  guards a fact the program records, not the quality of the model's judgment.
  Judgment belongs in the skill as guidance; see
  [docs/architecture.md](docs/architecture.md).
- **When you write or edit an entry skill** (`skills/<entry>/SKILL.md`), keep it a
  thin shell: it runs `loop-spec start` and points at the hub skill. The method lives
  in `skills/loop-spec/SKILL.md`, never in a stub. Reach bundled files with
  `${CLAUDE_SKILL_DIR}`, never another placeholder.
- **When you add guidance to the hub skill**, put what every run reads in `SKILL.md`,
  and only what some runs need (one run kind's changes, the PR template) in a file
  under `skills/loop-spec/references/`. Link each reference from `SKILL.md`, never from
  another reference: the lead may read a second-hand link only partly. Live runs showed
  the lead reads every phase's guidance in every run, so phases stay in `SKILL.md`.
  `tests/test_skills.py` checks the links.
- **When you write or edit guidance for the model** (a skill or an agent), state the
  goal and the reason rather than a procedure for its own sake, and keep it short.
  Check a model-behavior claim against [docs/models/](docs/models/README.md).
- **When you write a skill's or agent's `description`**, say what it does and when to
  use it, in the third person: it is injected into the system prompt and decides when
  the skill loads. `tests/test_skills.py` checks the Agent Skills format limits
  ([best practices](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices)).
- **When you add or change an agent** (`agents/<name>.md`), its `model`, `effort`, and
  `tools` go in its frontmatter; the lead dispatches it as `loop-spec:<name>`.
- **When you would run a live cycle against this checkout**, don't edit
  `skills/` or `agents/` while it runs. A live session reads the plugin tree as it
  goes; an edit mid-run changes what it reads out from under it.
- **When you write or edit markdown this repository ships**, name the reader in
  the first lines, give the document one job, and cite another file rather than
  copying its content. Fix a doc your change makes false in the same diff.
- **When you commit a change here**, use a conventional subject: `feat:`, `fix:`,
  `docs:`, or `chore:`. Include `Co-Authored-By: Claude <noreply@anthropic.com>`
  when the commit is AI-assisted.
- **When you change the version**, update all four in the same commit:
  `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, the README's
  `Current version:` line, and `VERSION` in
  `skills/loop-spec/program/loop_spec/__init__.py`. Each is a plain edit.
