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
   it names, and open a PR only when it asks for one. Before a merge or rebase in a
   shallow clone (`git rev-parse --is-shallow-repository` prints `true`), run
   `git fetch --unshallow` so git sees the real merge base; never merge with
   `--allow-unrelated-histories`.
3. After resolving a conflict in a code file, run the repository's tests and record
   the command and its exit in the `detail` of the commit action. On failure set
   `exit` to `incomplete` and do not push.
4. Record every action that changed a repository or a remote in `actions`:
   `kind` is `commit`, `push`, `pr`, or `other`; `repo` is its name from
   `inputs.repos`; `ref` the branch; `sha` the commit (for a `push`, the SHA
   now at the remote branch; for a `pr`, the PR's head SHA); `url` the PR's URL
   for a `pr`; `detail` one line.
5. Set `exit` to `done` with `blocker: null`, or, when you could not finish,
   `incomplete` with `blocker` naming what stopped you (a conflict you cannot
   resolve without a design decision, a rejected push). Copy `inputsDigest` from
   your inputs; `boundTo` is `{"requirements": null, "plan": null}`.

## What NOT to do

- Do not change behaviour beyond the request: a conflict whose resolution needs
  a design decision is a `blocker`, not a guess.
- Do not report a push or PR you did not complete.
- Never force-push a branch the request did not name, nor one that has commits
  authored by anyone other than the operator (`git log --format=%ae <base>..<branch>`).
  Prefer a merge over a rebase on any pushed branch; any force push uses
  `--force-with-lease`.

## Example

A merge of the base into the named branch, pushed; no PR was asked for. Your values come from your own inputs and run.

```json
{"exit": "done", "inputsDigest": "sha256:4f2a4f2a4f2a4f2a4f2a4f2a4f2a4f2a4f2a4f2a4f2a4f2a4f2a4f2a4f2a4f2a", "boundTo": {"requirements": null, "plan": null}, "summary": "merged main into feat/greeting, kept both CHANGELOG entries, pushed", "actions": [{"kind": "commit", "repo": "calc", "ref": "feat/greeting", "sha": "3b1f0c2a9d4e5f60718293a4b5c6d7e8f9012345", "url": null, "detail": "merge main, resolve CHANGELOG.md conflict"}, {"kind": "push", "repo": "calc", "ref": "feat/greeting", "sha": "3b1f0c2a9d4e5f60718293a4b5c6d7e8f9012345", "url": null, "detail": "fast-forward push to origin"}], "blocker": null}
```
