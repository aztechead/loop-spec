# Eval run 20260906-v620-haiku

Plugin 6.2.0 at 7dd29a1-dirty, model haiku, 5 task(s). Acceptance is `check.sh`; the judge is advisory.

| task | accepted | delivered | checks | phase | status | rounds | turns | agents | cost USD | min | app files | app +/- | artifact + | over-build | protected touched | judge meets/over |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| fib-cli | NO | no | 1/6 | plan | failed | 1 | 26 | 1 | 1.40 | 13.5 | 1 | +2/-0 | +194 | 0.03x | - | 0/0 |
| readme-sync | NO | no | 1/5 | plan | failed | 1 | 39 | 1 | 1.43 | 8.8 | 1 | +2/-0 | +195 | 0.1x | - | 0/2 |
| slugify-bug | NO | no | 0/2 | plan | failed | 1 | 88 | 1 | 1.29 | 8.3 | 1 | +2/-0 | +205 | 0.25x | - | 0/1 |
| todo-due | NO | no | 3/5 | execute | failed | 2 | 82 | 3 | 2.61 | 19.5 | 1 | +2/-0 | +1164 | 0.03x | - | 0/0 |
| wc-json | yes | no | 4/4 | execute | completed | 1 | 50 | 2 | 1.83 | 10.4 | 3 | +38/-1 | +0 | 1.09x | - | 3/1 |

Accepted 1/5. Delivered 0/5. Total cost USD 8.56. Total minutes 60.5.

- **fib-cli** failed: fib_py_exists: fib.py missing; fib_10_is_55: got 'python3: can't open file '/home/user/loop-spec/evals/.runs/20260906-v620-haiku/fib-cli/checkout/fib.py': [Errno 2] No such file or directory'; fib_0_is_0: got 'python3: can't open file '/home/user/loop-spec/evals/.runs/20260906-v620-haiku/fib-cli/checkout/fib.py': [Errno 2] No such file or directory'; tests_exist: no test files; readme_written
- **readme-sync** failed: readme_has_--exclude; readme_has_--dry-run; readme_has_--verbose; stale_flag_removed
- **slugify-bug** failed: tests_pass; behavior: got '----hello---- a--b'
- slugify-bug terminal reason: PLAN phase decision-coverage gate cannot parse spec file due to path resolution error in linter.
- **todo-due** failed: sort_due_order; due_shown
- **wc-json** wrote its terminal result by hand (no schema or version stamp): status untrusted
