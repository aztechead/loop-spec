# Foreign claimant reference consumer

A worked, end-to-end example of the handoff port's `foreign` rung
(`skills/shared/handoff-port.md`, `skills/execute/SKILL.md` "Rung 5 - foreign
claimants"): a bundle is exported and `put` on the port, and a separate,
out-of-process consumer claims it, does the work, verifies it, and completes
it.

**This is a reference consumer, not a supported product surface.** It
implements exactly one task type (deploy `app.py`) so the example stays
readable; a real production consumer would dispatch on `bundle["node"]` /
`bundle["task"]` / `bundle["brief"]` to select among many implementations.
Nothing here is imported by loop-spec itself, and it carries no compatibility
guarantee across releases.

## Files

- `app.py` — the deliverable the claimed work produces. Stdlib
  `http.server`, one route: `GET /` -> `200 text/plain "hello world"`.
  `--port N` (default 0, ephemeral); prints the bound port to stdout on
  startup.
- `claimant.py` — the production consumer. Talks to the port only through
  `bash lib/graph/port.sh`, never the adapter's storage directly.
- `verify.py` — the behavioral check a bundle's `verifyCommand` runs: starts
  the produced `app.py`, `GET /`s it, checks the body, tears it down.

## Running it by hand

From the repo root, with a real `feature.json` at `$FDIR`:

```bash
export LOOP_SPEC_PORT_ROOT=/tmp/loop-spec-port-demo   # or set LOOP_SPEC_PORT to a real adapter
mkdir -p "$LOOP_SPEC_PORT_ROOT"

bash lib/graph/handoff.sh export \
  --feature-dir "$FDIR" --node execute.worker --task task-hello \
  --verify "python3 $PWD/examples/foreign-claimant/verify.py $PWD/examples/foreign-claimant/output/app.py" \
  --brief "Serve GET / -> hello world (stdlib http.server)" \
  --files '["examples/foreign-claimant/output/app.py"]' \
  --out /tmp/bundle.json

bash lib/graph/port.sh put /tmp/bundle.json

python3 examples/foreign-claimant/claimant.py \
  --repo-root "$PWD" --feature-dir "$FDIR"

# claimant.py wrote examples/foreign-claimant/output/app.py; run it for real:
python3 examples/foreign-claimant/output/app.py --port 8080 &
curl http://127.0.0.1:8080/   # -> hello world
```

`claimant.py` claims exactly one bundle per invocation and exits; it is not a
poll loop. Running it repeatedly (a cron job, a Routine, a supervisor
process) is what turns it into a worker pool -- see the "What this rung does
not automate" note in `skills/execute/SKILL.md` for why loop-spec itself
doesn't provide that loop.
