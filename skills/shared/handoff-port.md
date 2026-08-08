# Handoff port contract

Distribution interface for claimable node-instance bundles. The plugin ships
exactly one reference adapter (`lib/graph/port-local.sh`); integrators point
`LOOP_SPEC_PORT` at their own executable. The transport is never learned by the
plugin. Executable definition: `tests/lib/graph-port-contract.test.sh`.

`lib/graph/port-local.sh` is a **conformance target**, not a recommended
production substrate.

## Operations

All operations are invoked as:

```bash
bash lib/graph/port.sh <op> ...
# or: "$LOOP_SPEC_PORT" <op> ...
```

### `put <bundle-json-file>`

Store a node-instance bundle. Stdout: `id=<instance-id>`. Exit 0 on success,
1 on invalid bundle, 2 on bad invocation.

### `get <id>`

Retrieve a stored bundle as JSON on stdout. Exit 0 when found, 1 when missing,
2 on bad invocation.

### `list [--claimable]`

Enumerate instance ids, one per line. With `--claimable`, only unclaimed or
lease-expired instances. Exit 0.

### `claim <id> <owner> <ttl-seconds>`

Take exclusive ownership for a bounded lease. Stdout:
`claimed=<id> owner=<owner> expires=<unix-epoch>`. Exit 0 on success, 1 if
another unexpired claim holds the instance, 2 on bad invocation.

A second claimant on an unexpired lease MUST fail (exit 1).

### `release <id>`

Relinquish a claim without completing. Exit 0 if released or already free,
1 if unknown id, 2 on bad invocation.

### `complete <id> <result-json-file>`

Return a contract-checked result. Re-checks the bundle state hash against
current feature state; a mismatch is rejected (exit 1, instance left
unmerged) rather than reconciled. Exit 0 on accepted merge, 2 on bad
invocation.
