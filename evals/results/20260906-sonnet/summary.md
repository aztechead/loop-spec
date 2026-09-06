# Eval run 20260906-sonnet

Plugin 6.1.0, model sonnet, 5 task(s). Acceptance is `check.sh`; the judge is advisory.

| task | accepted | checks | phase | status | rounds | turns | agents | cost USD | min | app files | app +/- | artifact + | over-build | protected touched | judge meets/over |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| fib-cli | yes | 6/6 | verify | None | 1 | 9 | 13 | 18.88 | 40.7 | 3 | +95/-1 | +947 | 1.58x | - | 3/1 |
| readme-sync | yes | 3/3 | deliver | failed | 1 | 36 | 7 | 11.52 | 22.1 | 1 | +4/-2 | +597 | 0.2x | - | 3/0 |
| slugify-bug | yes | 2/2 | deliver | failed | 1 | 194 | 7 | 9.12 | 20.5 | 2 | +4/-2 | +619 | 0.5x | - | 2/1 |
| todo-due | yes | 5/5 | iterate | None | 1 | 0 | 0 | 0.00 | 45.0 | 5 | +82/-6 | +984 | 1.37x | - | 3/0 |
| wc-json | yes | 4/4 | deliver | failed | 1 | 143 | 15 | 17.92 | 32.2 | 3 | +45/-1 | +906 | 1.29x | - | 3/0 |

Accepted 5/5. Total cost USD 57.44. Total minutes 160.5.

- readme-sync workaround: added profile.json to .git/info/exclude
- readme-sync terminal reason: gh is not on PATH
- slugify-bug workaround: added profile.json to .git/info/exclude
- slugify-bug terminal reason: gh is not on PATH
- todo-due workaround: deleted .loop-spec/profile.json
- todo-due workaround: added profile.json to .git/info/exclude
- wc-json workaround: added profile.json to .git/info/exclude
- wc-json terminal reason: gh is not on PATH
