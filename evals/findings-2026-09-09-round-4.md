# Outcome eval findings, 9 September 2026, round four

For the maintainer deciding what to fix after `evals/findings-2026-09-09-rounds-2-3.md`.
Same task (`fastapi-items`), same model (sonnet), same driver, now with `--phase-fresh`
(one driver round per phase, so each phase starts with an empty lead context) on plugin
commit c2fc8b9. Record: `evals/results/20260909-sonnet-fastapi-4/` (ignored).

## Headline

Round four escalated in EXECUTE after 56 minutes and 11.26 USD, accepted 1 of 7 checks.
The code never ran: the implementer installed Python through the sandbox's `uv`
(0.8.17), whose catalog ends at 3.14.0rc2, and current pydantic breaks on that rc2
stdlib. SPEC had already written the trap down (EVID-006: "no final 3.14 build") and
told EXECUTE to escalate rather than weaken `requires-python`, which it did. The rule
that would have avoided it (upgrade a stale installer first) was in the directive, and
round three had followed it; this round's grounding never learned that 3.14.7 exists,
because `lib/docs-probe.sh` could not reach endoflife.date from the sandbox and its
bare lookup then answered from the wrong place.

Phase-fresh held its cost promise: the four rounds cost 1.86, 1.95, 5.39, and 2.07 USD
(SPEC, DISCUSS, PLAN, EXECUTE) against round three's estimated 53.26 USD with one
lead context across the whole run.

## Numbers

| round | phase reached | cost USD | turns |
|---|---|---|---|
| 1 | discuss | 1.86 | 48 |
| 2 | plan | 1.95 | 50 |
| 3 | execute | 5.39 | 55 |
| 4 | execute (escalated) | 2.07 | 30 |

## Findings

### 1. The probe answered a runtime question from a package registry

`bash lib/docs-probe.sh latest python` on this network printed
`version=0.0.4 source=https://registry.npmjs.org/python ecosystem=npm`. The runtime
row asks endoflife.date, the proxy blocks that host, and the resolver fell through the
ecosystem order until npm's junk package named `python` answered. The directive says
`--ecosystem runtime` for a language, but a wrong answer with a source line is worse
than no answer. Fix: the runtime row has a mirror (the endoflife project's release
data on raw.githubusercontent.com, which the proxy allows), `fetch` distinguishes
"host never answered" from "host said no such thing", and a bare lookup whose runtime
sources never answered stops with `unverified` and names the `--ecosystem` flag.
`tests/lib/docs-probe.test.sh` pins all three.

### 2. Knowing the rule was not enough either

`skills/shared/engineering-directives.md` says a stale installer is upgraded before
anything is installed. The implementer's binding in `agents/implementer.md` summarized
the version row without that clause, and the implementer took `uv python install 3.14`
resolving to rc2 as "no final build available". Fix: the clause is in the binding.

### 3. Escalation was the right call and was honest

SPEC's Runtime constraint said to escalate rather than lower `requires-python`, and
EXECUTE did, with a reason that reproduced the crash outside the implementer's report.
Nothing to fix; the record is what an operator needs.

## Also fixed from the parallel run the user reported

The same day's PR 94 build hit three defects this round did not reach; each has a test.
The spec-writer wrote SPEC.md to the main checkout while the exit gate read the feature
worktree (`hooks/restrict-agent-paths.sh` now denies the write and names the path;
`phase-exit.sh` flags `[misplaced]` with the move). The converged floor vetoed a table it
could not parse, the lead rewrote VERIFICATION.md, the driver rewound through an empty
EXECUTE, and VERIFY died on the uncommitted file (`converged-floor.sh` reads the
verifier's table, `--shape` runs at VERIFY's exit, `verification-baseline.sh` ignores
`docs/loop-spec/`). The eval's `wc-json` control passed its fourth check on compiled
bytecode (`check.sh` greps `*.py` only).
