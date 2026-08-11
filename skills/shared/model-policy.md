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
task routes outrank both. Claude accepts `inherit`, a supported alias, or a full
model ID accepted by the installed CLI.

Pi and OpenCode ignore these selectors for inline or native task dispatch. A
loop-fleet subprocess may consume an explicit native value: a pi model ID or an
OpenCode `provider/model` ID. OpenCode task agents use generated-agent routes.
A harness never receives another harness's selector by default.

## Startup check

Claude startup resolves the exact configured selector set with
`feature-init.sh all-models` and probes it. `inherit` is the only selector in an
unconfigured install. Invalid configuration fails before feature work begins;
the host owns availability and its documented fallback behavior for a blocked
alias. Pi and OpenCode skip the Claude selector probe.

This policy deliberately separates model choice from GDD effort. `system1` and
`system2` change how a node approaches the work, not which catalog entry must
exist. See `skills/shared/dual-process.md`.
