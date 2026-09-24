---
name: direct
description: Do a mechanical git or pull-request operation the router judged to need no cycle (resolve conflicts, rebase, sync with base, push), then report every change made. Run by the lead for a `direct` run; not for ad-hoc use.
allowed-tools: Read, Grep, Glob, Bash, Edit, Write
---

# direct

The router judged that this request needs no spec, plan, or verification, so
you do it now, in this session, and report exactly what you did. No gate checks
your work beyond the facts you report: the program confirms each push against the
remote and each PR against its head, so report only what actually happened.

## Procedure

1. Read `inputs.request` and the router's reason (`inputs.products.route`).
   The repositories are under `inputs.repos`.
2. Do what the request names and nothing more: change and push only the branches
   it names, and open a PR only when it asks for one.
3. Record every action that changed a repository or a remote in `actions`:
   `kind` is `commit`, `push`, `pr`, or `other`; `repo` is its name from
   `inputs.repos`; `ref` the branch; `sha` the commit (for a `push`, the SHA
   now at the remote branch; for a `pr`, the PR's head SHA); `url` the PR's URL
   for a `pr`; `detail` one line.
4. Set `exit` to `done` with `blocker: null`, or, when you could not finish,
   `incomplete` with `blocker` naming what stopped you (a conflict you cannot
   resolve without a design decision, a rejected push). Copy `inputsDigest` from
   your inputs; `boundTo` is `{"requirements": null, "plan": null}`.

## What NOT to do

- Do not change behaviour beyond the request: a conflict whose resolution needs
  a design decision is a `blocker`, not a guess.
- Do not report a push or PR you did not complete.
- Never force-push a branch the request did not name.

## Example

```json
{"exit": "done", "inputsDigest": "sha256:0f1e", "boundTo": {"requirements": null, "plan": null}, "summary": "merged main into feat/greeting, kept both CHANGELOG entries, pushed", "actions": [{"kind": "commit", "repo": "calc", "ref": "feat/greeting", "sha": "3b1f0c2a9d4e5f60718293a4b5c6d7e8f9012345", "url": null, "detail": "merge main, resolve CHANGELOG.md conflict"}, {"kind": "push", "repo": "calc", "ref": "feat/greeting", "sha": "3b1f0c2a9d4e5f60718293a4b5c6d7e8f9012345", "url": null, "detail": "fast-forward push to origin"}], "blocker": null}
```
