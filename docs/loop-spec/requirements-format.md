# Requirements format

For maintainers editing SPEC requirements or consuming the pure inventory reader.

The v1 grammar is available for integration fixtures. Ordinary cycles retain their
legacy format until every producer and consumer supports v1. An explicit unknown or
malformed version fails; a persisted v1 contract cannot lose its metadata.

SPEC begins with frontmatter containing exactly one of each declaration:

```yaml
requirements_version: 1
requirements_owner: {"repository":"stable-repository-id","feature":"feature-slug"}
```

The owner must match the persisted contract. It names stable repository and feature
identities, independent of checkout location. Structured metadata uses single-line
JSON with duplicate keys rejected. Other frontmatter remains available to existing
consumers. `scenario_checks` must be a JSON object; command/input validation belongs
to the execution consumers.

Exactly one `### Good Enough` section contains required outcomes:

````markdown
### Good Enough

- [ ] GE-001: The user sees the saved value.
  Additional requirement prose continues at two spaces.
  - SC-001: Reloading displays the saved value.
    Additional scenario prose continues at four spaces.
    ```text
    saved value
    ```

### Exceptional

- [ ] Optional improvement.
````

Requirement IDs use `GE-` and scenario IDs use `SC-`, followed by a positive number
padded to at least three digits (`001`, `999`, `1000`). Extra leading zeroes are
invalid. Scenario IDs are local to their requirement. Duplicate IDs, missing or
empty scenarios, ambiguous indentation and duplicate sections fail with a source
line. History allocation and retirement enforcement belong to the state contract.

Examples use backtick or tilde fences of at least three characters, indented four
spaces beneath a scenario. Closing fences use the same character and at least the
opening length. Example contents are literal; apparent headings and identities
inside a fence create no records. Unclosed fences fail. Required coverage never
comes from `### Exceptional`. Supporting obligations are `- OBL-runtime: prose`
items under `## Constraints`; obligation IDs must be unique.

Requirement revisions hash UTF-8 canonical JSON containing `text` and `scenarios`.
Each scenario contributes `id`, `text`, and `examples`. Keys sort lexically, JSON
separators have no spaces, non-ASCII text is preserved, and scenarios sort by numeric
identity. Line endings normalize to LF. Structural indentation is removed and prose
wrapping joins with one space; paragraph boundaries and meaningful inline spacing
remain. Example content preserves its bytes after line ending and structural indent
normalization, including a newline for each line. Fence delimiters and language labels remain
part of the example, so changes to its executable language change the revision.

Checkboxes, source locations, document ordering, owner and commands do not affect a
requirement revision. Owner and version participate in the inventory digest, along
with sorted requirement identities/revisions and obligations. Commands require their
own execution evidence identity.

The Python API in [requirements.py](../../lib/requirements.py) exposes
`parse_spec(text, source, contract)`, `load_inventory(spec_path, feature_state)` and
`inventory_digest(inventory)`. Parsing returns `version`, `owner`, `requirements`,
`obligations` and `locations`. Requirements carry `id`, `revision`, `text`,
`scenarios`, and `location`; scenarios carry `id`, `text`, `examples`, and `location`.
Locations contain `source` and a one-based `line`. Legacy input returns version 0
with empty inventory lists: existing legacy gates still own positional criteria.
These functions never write state. Persisted ledger reconciliation is a separate
state integration step.

With `SPEC_PATH` set to a SPEC file and `FEATURE_DIR` to its feature state directory:

```bash
bash lib/requirements.sh inventory --spec "$SPEC_PATH" --feature-dir "$FEATURE_DIR"
```

Success prints the inventory as JSON and exits 0. Invalid input exits 1 with a
file/line diagnostic; repair that source and retry. Bad invocation exits 2.
SPEC input is limited to 16 MiB before decoding. Parsing uses memory proportional to
that bounded artifact, with identity sets for duplicate detection. No dependencies
beyond the repository's Python standard library runtime are required.

## Authoring commands (lib/graph/driver.py)

A feature never edits SPEC.md itself: `cycle-driver.sh spec skeleton|write|fill`
stage a candidate and publish it (and, under a v1 contract, the reconciled
`requirementsContract`) in one transaction -- `cmd_spec`, `publish_spec`. A driver-
rendered skeleton (`render_skeleton`, `apply_requirements_shape`) is unfilled
scaffolding, published plainly with no reconciliation attempted; the first real
`write` or `fill` is what reconciles the ledger.

`spec write --file DRAFT` (and `-` for stdin) under a v1 contract parses the draft
as-is when it already declares `requirements_version`/`requirements_owner`
(`declares_requirements_metadata`); a draft that declares neither is normalized only
-- the frontmatter declarations are added and each undated Good Enough item is
assigned the next stable `GE-NNN` from the contract's ledger, in document order, with
a synthesized `SC-001` carrying its own prose when it names no scenario itself
(`normalize_v1_draft`). An item that already carries a `GE-NNN:` prefix keeps it.

`spec fill --command/--expect` allocates a fresh stable ID from the same ledger
(`fill_requirement`); `--row` names an existing requirement by its `GE-NNN` identity
and never a document position -- a numeric alias (`--row 1`, `--row GE-9`) is refused
with exit 2. A `spec fill --json` batch reconciles in memory between the criteria in
one call so two new requirements never race for the same fresh ID.

`LOOP_SPEC_REQUIREMENTS_V1_FIXTURE=1` (`lib/feature-init.sh`) is a transitional,
fixture-only opt-in read once at cycle creation: it is not a user-facing downgrade
switch, and ordinary cycles stay on legacy until v1 activation.

## Execution inputs (lib/execution_inputs.py)

For a task author declaring `**Execution inputs:**` in PLAN, and for a driver
capturing the actual identity that contract names before and after a command runs.

A task's execution-inputs contract is single-line JSON with `version:1` and four
arrays -- `toolchains`, `localInputs`, `externalInputs`, `sensitiveInputs` -- plus an
optional `preparationReceipt`. A toolchain, external, or sensitive entry is
`{"name","argv","expectedIdentity"}`: `argv` runs with no shell expansion, bounded to
64 KiB of stdout and 30 seconds of wall time by default, and its trimmed output is
the identity (an external entry's probe instead prints JSON `{"identity","immutable"}`
and is rejected unless `immutable` is `true`). A local input is `{"root","paths"}`:
each declared path is traversed in sorted order, symlinks are resolved and rejected
if they escape the declared root, and every file's path/type/content is hashed in
64 KiB chunks. `lib/execution_inputs.py`'s module docstring is the source of truth
for the record shape, the per-file (16 MiB) and per-set (4096 file) ceilings, and the
argv-probe defaults; this section only orients a reader toward it.

`capture_inputs(root, contract, outputs)` returns that actual identity or raises
`ValueError` naming the offending path or probe: an escaping symlink, an unreadable
file, an unavailable or mutable external identity, a missing/malformed declaration,
or an input path overlapping a declared output. `compare_inputs(before, after)` and
`identity_changed(before, after)` diff two captures for a driver deciding whether a
command changed its declared inputs mid-run.

A `preparationReceipt` is optional context, never proof: a contract that carries one
with an empty `localInputs` array raises rather than returning a record, because a
receipt describes intent, not installed bytes (`docs/loop-spec/features/release-7-0/
SPEC.md`, "The driver owns execution observations"). Declare the local root the
receipt prepared so `capture_inputs` hashes what is actually there.

This module discovers nothing on its own: a check's dependencies must be named in
its contract, and an undeclared or unknown input blocks a current result rather than
being guessed.
