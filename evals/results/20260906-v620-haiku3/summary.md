# Eval run 20260906-v620-haiku3

Plugin 6.2.0 at 3f0bf1c, model haiku, 5 task(s). Acceptance is `check.sh`; the judge is advisory.

| task | accepted | delivered | checks | phase | status | rounds | turns | agents | cost USD | min | app files | app +/- | artifact + | over-build | protected touched | judge meets/over |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| fib-cli | yes | no | 6/6 | execute | failed | 1 | 26 | 2 | 2.03 | 12.1 | 4 | +149/-2 | +502 | 2.48x | - | 3/1 |
| readme-sync | yes | yes | 3/3 | deliver | completed | 1 | 110 | 0 | 1.49 | 10.6 | 2 | +6/-2 | +451 | 0.3x | - | 3/1 |
| slugify-bug | yes | no | 2/2 | deliver | escalated | 1 | 97 | 2 | 1.40 | 9.8 | 2 | +4/-0 | +523 | 0.5x | - | 3/1 |
| todo-due | NO | no | 3/5 | execute | failed | 1 | 22 | 1 | 1.09 | 11.8 | 1 | +2/-0 | +558 | 0.03x | - | 0/0 |
| wc-json | yes | no | 4/4 | verify | failed | 1 | 17 | 2 | 1.49 | 11.1 | 3 | +20/-1 | +487 | 0.57x | - | 3/1 |

Accepted 4/5. Delivered 1/5. Total cost USD 7.51. Total minutes 55.4.

- slugify-bug terminal reason: candidate repository has uncommitted changes
- **todo-due** failed: sort_due_order; due_shown
