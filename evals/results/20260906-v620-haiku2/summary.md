# Eval run 20260906-v620-haiku2

Plugin 6.2.0 at 9fa1c3b, model haiku, 5 task(s). Acceptance is `check.sh`; the judge is advisory.

| task | accepted | delivered | checks | phase | status | rounds | turns | agents | cost USD | min | app files | app +/- | artifact + | over-build | protected touched | judge meets/over |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| fib-cli | NO | no | 1/6 | plan | failed | 1 | 23 | 2 | 1.12 | 9.8 | 1 | +2/-0 | +211 | 0.03x | - | 0/0 |
| readme-sync | yes | no | 3/3 | verify | escalated | 1 | 25 | 3 | 1.62 | 10.2 | 2 | +7/-2 | +285 | 0.35x | - | 3/1 |
| slugify-bug | yes | yes | 2/2 | completed | completed | 1 | 21 | 4 | 2.29 | 10.7 | 2 | +4/-0 | +426 | 0.5x | - | 3/1 |
| todo-due | NO | no | 3/5 | execute | None | 1 | 1 | 4 | 1.13 | 10.8 | 4 | +62/-1 | +831 | 1.03x | - | 1/1 |
| wc-json | NO | no | 3/4 | plan | failed | 1 | 18 | 2 | 1.12 | 11.0 | 1 | +2/-0 | +638 | 0.06x | - | 0/0 |

Accepted 2/5. Delivered 1/5. Total cost USD 7.29. Total minutes 52.5. CUT OFF by the account usage limit: 2/5; those rows measure the account, not the plugin. Re-run them after the window resets.

- **fib-cli** failed: fib_py_exists: fib.py missing; fib_10_is_55: got 'python3: can't open file '/home/user/loop-spec/evals/.runs/20260906-v620-haiku2/fib-cli/checkout/fib.py': [Errno 2] No such file or directory'; fib_0_is_0: got 'python3: can't open file '/home/user/loop-spec/evals/.runs/20260906-v620-haiku2/fib-cli/checkout/fib.py': [Errno 2] No such file or directory'; tests_exist: no test files; readme_written
- readme-sync terminal reason: VERIFY phase: verification artifact formatting issue (grounding section lint). Core feature complete: README.md updated with all flags, all 5 acceptance criteria passing. Issue is artifact format, not implementation.
- **todo-due** cut off by the account usage limit after 10.8 min; not a plugin outcome
- **todo-due** failed: sort_due_order; due_shown
- **wc-json** cut off by the account usage limit after 11.0 min; not a plugin outcome
- **wc-json** failed: json_flag_works: output: usage: wc_tool.py [-h] paths [paths ...]
