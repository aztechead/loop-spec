# loop-spec Contributor Guidelines

For a contributor changing this repository. Each bullet names a moment you can
recognize while working and what to do; a rule with no trigger does not fire.

- **When you would add a dependency to the shipped program**, don't. Runtime is
  `bash` (the one-line launcher only), `git`, and `python3` >= 3.11, stdlib only.
  Shipped code lives under `skills/loop-spec/program/loop_spec/`: one module, one
  reason to change (`state.py` owns `state.json`, `postconditions.py` only answers
  whether a claimed exit holds, `controller.py` is the one place that transitions a
  phase). `examples/` holds a reference consumer that may import the SDK it
  demonstrates and says in its own README that it is not a supported surface.
- **When you would write an offline test for a whole cycle**, don't. Unit tests
  (`skills/loop-spec/program/tests/`, `python3 -m unittest discover -s tests`) cover
  the program's deterministic Python only: state, contract, routing,
  postconditions, schemas. There is no fake runner and no offline cycle suite.
  Model-driven behavior is shown by a live run, recorded in
  [docs/loop-spec/live-runs-7.0.md](docs/loop-spec/live-runs-7.0.md), never
  simulated.
- **When you change a route or a postcondition**, edit
  [docs/loop-spec/phase-interface-7.0.md](docs/loop-spec/phase-interface-7.0.md) in
  the same diff. `postconditions.ROUTES` and `external.POSTCONDITION_TEXT`
  transcribe that document; a change to one without the other is a lie one of them
  now tells.
- **When you write or edit a skill stub** (`skills/<entry>/SKILL.md`), keep it a
  thin shell to the program: it locates and runs `loop-spec`, reads
  `LOOP_SPEC_NEXT`, and acts on the file it names. Phase content lives in the
  program, never in a stub. Reach bundled files with `${CLAUDE_SKILL_DIR}`, never
  another placeholder.
- **When you add or change a role** (`skills/loop-spec/roles/<name>/`), it is a
  skill: `SKILL.md` (the prompt body) plus `schema.json` (the result shape
  `roles.load_role` validates against, regardless of which skill a project binds
  in its place). A role never cites a script; a program module dispatches it.
- **When you would run a live cycle against this checkout**, don't edit
  `skills/loop-spec/program/` or `skills/*/` while it runs. A live run's supervisor
  or session reads the plugin tree as it goes; an edit mid-run changes what it
  reads out from under it.
- **When you write or edit markdown this repository ships**, name the reader in
  the first lines, give the document one job, and cite another file rather than
  copying its content. Fix a doc your change makes false in the same diff.
- **When you commit a change here**, use a conventional subject: `feat:`, `fix:`,
  `docs:`, or `chore:`. Include `Co-Authored-By: Claude <noreply@anthropic.com>`
  when the commit is AI-assisted.
- **When you change the version**, update all four in the same commit:
  `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, the README's
  `Current version:` line, and every `skills/*/manifest.toml`. There is no
  bump script in 7.x; each file is a plain edit.
