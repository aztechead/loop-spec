# Model policy

The portable model policy is simple: inherit unless the operator opts into a
specific route. The executable source is `lib/feature-init.sh`; the complete
contract and precedence rules are in `skills/shared/model-matrix.md`.

## Defaults

Every phase, role agent, and standalone skill can run on the model that launched
the session. Claude Code and OpenCode both define inheritance for subagents, so
loop-spec requires no named model family and no fixed provider catalog.

Claude dispatches OMIT the Agent `model` key when the role inherits; that tool
parameter is an alias enum and rejects the literal `inherit`. OpenCode task calls
omit a model and let the generated subagent inherit its primary agent. Pi performs
non-fleet roles inline on the session model.

## Explicit routes

`LOOP_SPEC_PHASE_MODEL_<PHASE>` and `LOOP_SPEC_MODEL_<ROLE>` are operator-owned
selectors stored in feature state. Role routes outrank phase routes; concrete
task routes outrank both. Claude role routes accept `inherit` or a supported
Agent alias. A Claude phase route may also carry a full CLI model ID when a
fresh main-context launcher consumes it; role Agents then inherit that main
model.

Pi and OpenCode ignore these selectors for inline or native task dispatch. An
implementer loop-fleet subprocess may consume an explicit native value: a pi
model ID or an OpenCode `provider/model` ID. Other native role pins fail early;
OpenCode task agents use generated-agent routes.
A harness never receives another harness's selector by default.

## Startup check

Claude startup resolves the exact configured selector set with
`feature-init.sh all-models`. An unconfigured install contains only `inherit`
and performs zero Agent probes. Explicit Agent aliases are probed; full phase
IDs are checked by the fresh CLI/SDK launcher that consumes them. Invalid
configuration fails before feature work begins. Pi and OpenCode skip the Claude
selector probe.

This policy deliberately separates model choice from GDD effort. `system1` and
`system2` change how a node approaches the work, not which catalog entry must
exist. See `skills/shared/dual-process.md`.
