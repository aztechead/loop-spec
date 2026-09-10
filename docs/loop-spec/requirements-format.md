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
