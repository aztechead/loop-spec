"""The entry registry: every way a run starts, and what each one takes.

Use `ENTRIES` wherever the set of entries matters (the CLI's subcommands, the
controller's dispatch, the router's choices). Data only: this module imports nothing
from the program, so the core and every plug-in can read it. An entry's `use` is the
sentence its skill stub's `description` also carries (a test holds them equal).
"""
from dataclasses import dataclass


@dataclass(frozen=True)
class Entry:
    name: str
    use: str
    takes: str  # "request" (--request / --request-file) or "pr" (--pr)


ENTRIES: dict[str, Entry] = {e.name: e for e in (
    Entry("cycle", "Run the full loop-spec cycle (SPEC, PLAN, EXECUTE, VERIFY, ITERATE, DELIVER) on a feature "
          "request or spec file and deliver a PR. Use for a feature or change that needs planning, implementation, "
          "and verification. Not for a one-line fix (use micro), a failing test or bug report (use debug), or PR "
          "review comments (use revise).", "request"),
    Entry("micro", "Make a small, well-defined change (a one-file fix, a typo, a tiny tweak) in one autonomous pass. "
          "Use for a change too small to need a spec/plan/execute/verify cycle. Not for a feature that needs planning "
          "(use cycle) or a bug that needs root-cause investigation (use debug).", "request"),
    Entry("debug", "Diagnose and fix a specific failure: reproduce a bug or error report, find the root cause, and land "
          "a fix with a regression test. Use for a stack trace, a failing test, or a reported bug. Not for a new "
          "feature (use cycle) or a one-line style/typo fix with no bug (use micro).", "request"),
    Entry("revise", "Address reviewer feedback on an already-open pull request. Use when a human or bot left PR review "
          "comments to resolve. Not for starting new work (use cycle) or fixing a bug found outside review "
          "(use debug).", "pr"),
)}

# The phases a run can be resumed at by name (`loop-spec <phase> --slug`).
RESUME_PHASES = ("spec", "plan", "execute", "verify", "iterate", "deliver")
