# A perf run

For the lead of a loop-spec run of kind `perf`: a measured part of the code to make faster
or smaller. Read it before the spec; it changes the workflow in SKILL.md as follows, and
everything else stands.

- **Spec:** one measured criterion: a `check` whose output ends with a number on its last
  non-empty line, plus `better` (`"lower"` or `"higher"`) and `by` (a percentage such as
  `"10%"`). The check repeats itself when it needs to, for example
  `for i in 1 2 3; do ...; done | sort -n | sed -n 2p`. A benchmark worth trusting:
  - it measures what limits the number, not something nearby;
  - it repeats within noise (repeat inside the check);
  - it exercises the code the change touches;
  - base and head run on the same machine with the same inputs.
- **Verify:** `LS verify --base` first; it records the base number. The head verify then
  compares with it and fails a criterion that misses its target.
- **Execute:** one hypothesis at a time. Keep a commit only when the number moves; revert
  what did not help.
