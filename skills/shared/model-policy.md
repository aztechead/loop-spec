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
omit a model and let the generated subagent inherit its primary agent. ADK role
agents inherit the mounted app's model unless their charter names an ADK model ID.

## Explicit routes

`LOOP_SPEC_PHASE_MODEL_<PHASE>` and `LOOP_SPEC_MODEL_<ROLE>` are operator-owned
selectors stored in feature state. Their precedence is stated once, in
`skills/shared/model-matrix.md`, and implemented once, in `lib/feature-init.sh`
— this file deliberately does not restate the order, so the two cannot disagree.

Which VALUES each route accepts is the part that differs by consuming surface.
Claude role routes accept `inherit` or a supported Agent alias. A Claude phase
route may also carry a full CLI model ID when a fresh main-context launcher
consumes it; role Agents then inherit that main model.

OpenCode and ADK do not consume Claude aliases. An implementer loop-fleet
subprocess may consume an explicit native value: an OpenCode `provider/model` ID,
or a Gemini / LiteLLM ID under ADK. Other native role pins fail early; OpenCode
task agents use generated-agent routes and ADK role agents use their charters.
A harness never receives another harness's selector by default.

## Startup check

Claude startup resolves the exact configured selector set with
`feature-init.sh all-models`. An unconfigured install contains only `inherit`
and performs zero Agent probes. Explicit Agent aliases are probed; full phase
IDs are checked by the fresh CLI/SDK launcher that consumes them. Invalid
configuration fails before feature work begins. OpenCode and ADK skip the Claude
selector probe.

This policy deliberately separates model choice from GDD effort. `system1` and
`system2` change how a node approaches the work, not which catalog entry must
exist. See `skills/shared/dual-process.md`.
