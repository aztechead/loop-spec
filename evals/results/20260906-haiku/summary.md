# Eval run 20260906-haiku

Plugin 6.1.0, model haiku, 5 task(s). Acceptance is `check.sh`; the judge is advisory.

| task | accepted | checks | phase | status | rounds | turns | agents | cost USD | min | app files | app +/- | artifact + | over-build | protected touched | judge meets/over |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| fib-cli | yes | 6/6 | verify | failed | 1 | 28 | 9 | 3.31 | 27.5 | 4 | +208/-2 | +660 | 3.47x | - | 3/2 |
| readme-sync | yes | 3/3 | None | completed | 1 | 160 | 2 | 3.24 | 17.6 | 1 | +30/-4 | +441 | 1.5x | - | None/None |
| slugify-bug | yes | 2/2 | deliver | None | 1 | 18 | 3 | 1.67 | 11.4 | 1 | +2/-0 | +302 | 0.25x | - | 3/0 |
| todo-due | NO | 3/5 | spec | None | 1 | 16 | 0 | 0.16 | 1.6 | 0 | +0/-0 | +0 | 0.0x | - | 0/0 |
| wc-json | yes | 4/4 | deliver | failed | 1 | 33 | 1 | 2.13 | 15.3 | 1 | +6/-1 | +207 | 0.17x | - | 3/0 |

Accepted 4/5. Total cost USD 10.52. Total minutes 73.4.

- readme-sync terminal reason: Delivery infrastructure blocked PR publication
- **todo-due** failed: sort_due_order; due_shown
