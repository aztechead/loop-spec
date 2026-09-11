#!/usr/bin/env bash
# harness.sh - Identify the agent harness loop-spec is running under.
#
# loop-spec ships for four peer harnesses from one source tree: Claude Code
# (including the Claude Agent SDK), opencode (https://opencode.ai), Google's
# Agent Development Kit (https://google.github.io/adk-docs/), and OpenAI Codex
# (https://developers.openai.com/codex). None of them is the
# reference implementation — each expresses the same cycle through the surface it
# actually has, and every difference between them is a branch keyed on this one
# probe rather than an ad hoc tool sniff. The adaptation contracts that consume
# these answers are skills/shared/claude-harness.md,
# skills/shared/opencode-harness.md, skills/shared/adk-harness.md, and
# skills/shared/codex-harness.md.
#
# Usage:
#   harness.sh detect      -> "claude" | "opencode" | "adk" | "codex"
#   harness.sh cli         -> headless dispatch binary for THIS harness
#                             ("claude" | "opencode" | "adk" | "codex"); loop-fleet rungs
#                             spawn this.
#   harness.sh subagents   -> "true" | "false"  (does the harness have a
#                             one-shot subagent tool taking {description,
#                             prompt, subagent_type}: claude has Agent,
#                             opencode has task, adk has the bundled
#                             dispatch_subagent tool over AgentTool, Codex has
#                             spawn_agent — the call shape is mapped per
#                             contract, the capability is the same)
#   harness.sh entrypoint  -> the raw CLAUDE_CODE_ENTRYPOINT stamp, or
#                             "unknown" when unset (see below)
#   harness.sh headless    -> "true" | "false" (is this a one-shot, unattended
#                             invocation with no human and no persistent
#                             session? the single execution-profile answer)
#   harness.sh attended    -> "true" | "false" (is a person PROVEN to be at the
#                             keyboard? "true" only on evidence: the operator's
#                             word, the harness's interactive stamp, or a bridge
#                             harness that asserts nothing else; every unknown
#                             answers "false", see below)
#   harness.sh attended-reason -> stable reason for the attended answer
#   harness.sh loop-runtime -> "true" | "false" (can this invocation keep a
#                              synchronous, long-running fleet tool call alive?)
#   harness.sh loop-runtime-reason -> stable reason for rung telemetry
#   harness.sh session-layer -> "session" | "in-harness" (may EXECUTE run each
#                               agent node as its own headless CLI process through
#                               extensions/sessions/? "session" only when the
#                               invocation is headless, a profile exists for this
#                               harness's CLI, the CLI is on PATH, and python3 has
#                               tomllib; every unknown leg answers "in-harness")
#   harness.sh session-layer-reason -> stable reason for rung telemetry
#   harness.sh protected-path --path PATH --feature-dir DIR
#                           -> "protected=yes|no reason=<text>" on one line:
#                              is PATH one of this feature's driver-owned
#                              publication paths? SPEC.md/PLAN.md/
#                              VERIFICATION.md/PATTERNS.md (resolved through
#                              the feature's own artifact pointers, defaulting
#                              to docs/loop-spec/features/<slug>/) are protected
#                              when the route is oneshot (lib/graph/probes/
#                              oneshot.sh) or requirementsContract.format is
#                              "v1"; feature.json, feature.json.bak, and
#                              tasks.json are always protected; so are
#                              observations/** and its final/ subtree,
#                              publication-generations/**, and
#                              migration-generations/** under the feature
#                              directory. publication-staging/**, dispatch/**,
#                              and review-attempts/** answer "no" (legitimate
#                              maker staging). Every guard and adapter
#                              (hooks/pre-tool-guard.py's callees,
#                              extensions/opencode/loop-spec.ts,
#                              extensions/adk/loop_spec_adk/plugin.py through
#                              that same hook) reads this one answer instead of
#                              reimplementing the path rule. An unreadable
#                              feature directory, missing feature.json, or any
#                              other probe failure answers "yes": fail safe,
#                              and the reason never claims evidence exists.
#
# Detection order (first match wins):
#   1. LOOP_SPEC_HARNESS=claude|opencode|adk|codex   explicit override. The retired
#      value `pi` is an error instead of silently selecting another harness. # retired-harness-diagnostic
#      The bundled
#      opencode plugin (extensions/opencode/loop-spec.ts), ADK bridge
#      (extensions/adk/loop_spec_adk/bridge.py), and Codex installer/hooks
#      (lib/codex-install.sh, hooks/codex-shell-env.sh) all export it into every
#      shell invocation — opencode through the documented `shell.env` plugin
#      hook, ADK through its session-aware Execute wrapper, Codex through
#      shell_environment_policy.set plus a PreToolUse Bash rewrite — so under
#      those harnesses this is the NORMAL signal, not just the escape hatch.
#      Unknown values fall through.
#   2. CLAUDECODE=1                  set by Claude Code's Bash tool -> claude
#   3. default                       -> claude (back-compat: every pre-2.14
#                                     install is a Claude Code plugin)
#
# Neither opencode, ADK, nor Codex stamps an identifying variable of its own
# that this probe may treat as proof: opencode's shell env is a plain
# process.env spread plus plugin `shell.env` output, ADK runs shell commands
# through whatever environment the embedding program built, and Codex's
# documented subprocess env is `shell_environment_policy` plus plugin hook
# variables that exist only inside hook processes. Detection under those
# harnesses therefore REQUIRES the bundled bridge; there is no weak hint to
# fall back on, and inventing one would guess wrong on any machine with
# another harness installed.
#
# Headless proof (`entrypoint` / `headless`):
#   Claude Code stamps CLAUDE_CODE_ENTRYPOINT into every child process it spawns,
#   naming how the session was launched. Three of its values are one-shot agent
#   invocations with no interactive session behind them:
#     sdk-cli  `claude -p` / `--print` (the CLI rewrites the `cli` stamp to
#              `sdk-cli` when print mode is on)
#     sdk-py   the Claude Agent SDK for Python (`claude-agent-sdk`)
#     sdk-ts   the Claude Agent SDK for TypeScript
#   `cli` is the interactive TUI; the remaining values (mcp, bench, remote,
#   claude-desktop, claude-code-github-action, ...) are neither proven headless
#   nor proven interactive here, so they stay unknown and fail safe.
#
# Attended proof (`attended`):
#   The inverse question, asked by the SessionStart directives that only a person
#   should receive (hooks/team/micro-inject.sh). It is NOT `headless` negated: an
#   unknown stamp is "not headless" and also "not attended". The safe direction
#   differs per caller. A directive injected into a headless cycle run competed
#   with the cycle skill and won (the dda2cca wc-json run: the lead followed the
#   ad-hoc micro protocol, edited in place, and never began a cycle;
#   port audit 1, F1), so a directive meant for a
#   person is injected only when a person is proven. Evidence, strongest first:
#     1. LOOP_SPEC_NON_INTERACTIVE=1 / EXECUTION_PROFILE=headless -> false
#     2. a headless entrypoint stamp -> false (a fact; it outranks the claim below)
#     3. LOOP_SPEC_EXECUTION_PROFILE=interactive -> true (the operator's word)
#     4. Claude Code: the `cli` stamp -> true; any other stamp or none -> false
#     5. opencode, ADK, Codex: true. They stamp nothing; their one-shot launchers
#        assert LOOP_SPEC_NON_INTERACTIVE=1 (leg 1), so the bridge's silence is the
#        harness's word that a session is attended, the only channel it has.
#
#   This matters because it is DETERMINISTIC. Before it, an unattended run had to
#   remember to export LOOP_SPEC_NON_INTERACTIVE=1; forgetting it left the
#   execution profile "unproven", and a stale LOOP_SPEC_EXECUTION_PROFILE=interactive
#   export could actively claim a persistent runtime that a `claude -p` job does
#   not have — which is how a headless run gets routed onto the loop-fleet rung it
#   cannot execute. A stamped headless entrypoint is a fact and outranks that claim.
#
#   opencode, ADK, and Codex publish no equivalent stamp, so they assert the
#   profile on the channel that already exists: `opencode run`, `adk run`, and
#   `codex exec` are one-shot, and the bundled launch paths export
#   LOOP_SPEC_NON_INTERACTIVE=1 for one-shot runs (ADK/Codex: loop.py and
#   issue-intake.sh; direct `adk run` / `codex exec` callers set it explicitly,
#   unlike persistent `adk web` / `adk api_server` or the Codex TUI). That is
#   an assertion rather than a proof, which is why it ranks below a stamp and
#   above an inherited EXECUTION_PROFILE claim.
#
# Session layer (`session-layer`):
#   LOOP_SPEC_SESSION_LAYER=1|0 is the operator's word and outranks the probe; unset,
#   the answer is "session" only when every leg above is proven. The probe never
#   launches anything: extensions/sessions/session_run.py exits 3 on its own when
#   the binary or the interpreter is missing at launch time.
#
# detect/cli/subagents/entrypoint/headless/attended/session-layer/protected-path
# always exit 0 with the answer on stdout; an unknown command, or protected-path
# called without both --path and --feature-dir, exits 2.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_PROFILES="$SCRIPT_DIR/../extensions/sessions/profiles"
ONESHOT_PROBE="$SCRIPT_DIR/graph/probes/oneshot.sh"
FEATURE_READ="$SCRIPT_DIR/feature-read.sh"

# Entrypoint stamps that prove a one-shot, unattended invocation.
HEADLESS_ENTRYPOINTS=" sdk-cli sdk-py sdk-ts "
# Entrypoint stamps that prove a person at the keyboard: the interactive TUI.
ATTENDED_ENTRYPOINTS=" cli "

entrypoint() {
  local ep="${CLAUDE_CODE_ENTRYPOINT:-}"
  if [[ -n "$ep" ]]; then echo "$ep"; else echo "unknown"; fi
}

# "true" when the entrypoint stamp itself proves a headless invocation.
entrypoint_headless() {
  local ep
  ep="$(entrypoint)"
  if [[ "$HEADLESS_ENTRYPOINTS" == *" $ep "* ]]; then echo "true"; else echo "false"; fi
}

# One execution-profile answer, from strongest evidence down:
#   1. operator assertion (LOOP_SPEC_NON_INTERACTIVE / EXECUTION_PROFILE=headless)
#   2. the harness's own entrypoint stamp
#   3. EXECUTION_PROFILE=interactive, or no evidence -> not headless
headless() {
  if [[ "${LOOP_SPEC_NON_INTERACTIVE:-}" == "1" || "${LOOP_SPEC_EXECUTION_PROFILE:-}" == "headless" ]]; then
    echo "true"
  else
    entrypoint_headless
  fi
}

detect() {
  case "${LOOP_SPEC_HARNESS:-}" in
    claude|opencode|adk|codex) echo "${LOOP_SPEC_HARNESS}"; return ;;
    pi) # retired-harness-diagnostic
      echo "harness.sh: LOOP_SPEC_HARNESS=pi was removed in 4.0.0; choose claude, opencode, adk, or codex" >&2 # retired-harness-diagnostic
      return 2
      ;;
  esac
  if [[ "${CLAUDECODE:-}" == "1" ]]; then
    echo "claude"; return
  fi
  echo "claude"
}

# The one place every guard and adapter asks "is this write onto a driver-owned
# publication path?" (SPEC "The driver owns execution observations" / "Migration
# preserves originals..."). Callers already know which feature a candidate path
# belongs to -- hooks/restrict-agent-paths.sh and hooks/team/result-forgery-guard.sh
# already extract the slug from the path -- so this takes an explicit
# --feature-dir rather than searching for one; a second implementation of that
# search here would drift from the callers' own.
protected_path() {
  local path="" feature_dir=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --path) path="${2:-}"; shift 2 ;;
      --feature-dir) feature_dir="${2:-}"; shift 2 ;;
      *) echo "harness.sh protected-path: unknown flag '$1' (usage: --path PATH --feature-dir DIR)" >&2; exit 2 ;;
    esac
  done
  [[ -n "$path" && -n "$feature_dir" ]] || {
    echo "harness.sh protected-path: --path and --feature-dir are both required" >&2
    exit 2
  }

  deny() { printf 'protected=yes reason=%s\n' "$1"; exit 0; }
  allow() { printf 'protected=no reason=%s\n' "$1"; exit 0; }

  local fd_real slug target
  fd_real="$(cd "$feature_dir" 2>/dev/null && pwd -P)" || deny "unknown feature dir ($feature_dir does not exist)"
  [[ -f "$fd_real/feature.json" ]] || deny "unknown feature dir (no feature.json in $feature_dir)"
  slug="$(bash "$FEATURE_READ" "$fd_real" -r --filter '.slug // ""' 2>/dev/null)" || deny "feature.json could not be read"
  [[ -n "$slug" ]] || deny "feature.json has no slug"

  # A relative candidate (hooks/team/result-forgery-guard.sh's shell-command
  # matches are not pre-resolved the way a Write tool's file_path already is)
  # is joined against the checkout root implied by fd_real's own
  # .loop-spec/features/<slug> suffix -- not the git-toplevel/workspace lookup
  # below, which the state-dir case never needs and a symlinked checkout could
  # answer differently for.
  if [[ "$path" == /* ]]; then
    target="$path"
  else
    target="${fd_real%%/.loop-spec/features/*}/$path"
  fi

  # Resolve symlinks before every comparison below: a candidate that is itself a
  # symlink into a protected path (or sits under a symlinked directory that resolves
  # into one) must answer protected=yes even though the literal $target does not
  # textually match. lib/resolve-symlink.sh does the resolution -- shared with
  # hooks/restrict-agent-paths.sh's own resolve_target so the two guards never
  # disagree about where a path lands. Resolution failure (missing python3, an
  # unreadable parent) falls back to the literal target rather than denying blind --
  # the route/format checks below still run against whatever target names.
  target="$(bash "$SCRIPT_DIR/resolve-symlink.sh" "$target" 2>/dev/null)" || true

  # Runtime-state paths (under the feature's own .loop-spec/features/<slug>): the
  # driver's staging/journal/observation set, checked before the docs tree so a
  # feature-dir-relative name never collides with a docs-tree one.
  case "$target" in
    "$fd_real"/observations/*)
      deny "observations/** is a driver-owned execution record (lib/execution_observation.py)" ;;
    "$fd_real"/publication-generations/*)
      deny "publication-generations/** is the driver's publication journal (lib/artifact_publication.py)" ;;
    "$fd_real"/migration-generations/*)
      deny "migration-generations/** is the driver's migration journal (lib/requirements_migrate.py)" ;;
    "$fd_real"/publication-staging/*)
      allow "publication-staging/** is where a maker legitimately stages a publication before the driver commits it" ;;
    "$fd_real"/dispatch/*|"$fd_real"/review-attempts/*)
      allow "$(basename "$(dirname "$target")")/ is not part of this feature's protected set" ;;
    "$fd_real"/feature.json|"$fd_real"/feature.json.bak)
      deny "feature.json is written only by lib/feature-write.sh" ;;
    "$fd_real"/tasks.json)
      deny "tasks.json is written only by the driver (lib/graph/driver.py / cycle-driver.sh)" ;;
  esac

  # Authoritative markdown: protected once this feature is on the oneshot route
  # or the v1 requirements format, resolved through the feature's own artifact
  # pointers so a relocated pointer (artifact_publication.py's registry) is
  # still covered, not just the default docs/loop-spec/features/<slug>/ layout.
  # An unreadable spec keeps the driver-owned reading rather than falling open
  # to the full route's human-authored one (an unreadable spec may be what a
  # hand write just broke); so does a probe that produced no answer at all.
  local format route by_route=0 pair key name ptr abs
  format="$(bash "$FEATURE_READ" "$fd_real" -r --filter '.requirementsContract.format // "legacy"' 2>/dev/null)" || format="legacy"
  route="$(bash "$ONESHOT_PROBE" --feature-dir "$fd_real" 2>/dev/null)" || route=""
  if [[ "$format" == "v1" ]]; then
    by_route=1
  elif [[ "${route%% *}" == "route=oneshot" ]]; then
    by_route=1
  elif [[ "${route%% *}" != "route=full" ]]; then
    by_route=1  # empty or unrecognized answer: fail safe
  else
    case "$route" in
      *"frontmatter missing"*|*"frontmatter unterminated"*|*"could not be read"*|*"not readable"*) by_route=1 ;;
    esac
  fi
  if [[ "$by_route" == "1" ]]; then
    local ws_root root
    ws_root="$(bash "$FEATURE_READ" "$fd_real" -r --filter \
      'if (.workspace != null and (.workspace.mode // "") != "single") then .workspace.root else "" end' 2>/dev/null)" || ws_root=""
    if [[ -n "$ws_root" ]]; then
      root="$ws_root"
    else
      root="$(git -C "$fd_real" rev-parse --show-toplevel 2>/dev/null)" || deny "$fd_real is not inside a git repository"
    fi
    for pair in spec:SPEC.md plan:PLAN.md verification:VERIFICATION.md patterns:PATTERNS.md; do
      key="${pair%%:*}"; name="${pair#*:}"
      ptr="$(bash "$FEATURE_READ" "$fd_real" -r --filter ".artifacts.${key} // \"\"" 2>/dev/null)" || ptr=""
      [[ -n "$ptr" ]] || ptr="docs/loop-spec/features/$slug/$name"
      if [[ "$ptr" == /* ]]; then abs="$ptr"; else abs="$root/$ptr"; fi
      if [[ "$target" == "$abs" ]]; then
        deny "$name is driver-owned on this feature's requirements format/route (format=$format, ${route:-route probe gave no answer})"
      fi
    done
  fi

  allow "not one of feature '$slug's driver-owned publication paths"
}

cmd="${1:-}"
case "$cmd" in
  detect)
    detect
    ;;
  cli)
    # Today the harness name IS the headless binary name for all four
    # harnesses (claude -p / opencode run --format json / adk run --jsonl /
    # codex exec --json). Kept as a separate verb so call sites read as intent
    # (which binary do I spawn) and so a future harness where the two diverge
    # only changes here.
    detect
    ;;
  subagents)
    # Capability, not harness name: all four harnesses expose a one-shot
    # dispatch — claude's Agent, opencode's task, the dispatch_subagent tool
    # the ADK bridge builds over AgentTool, and Codex spawn_agent — so the
    # subagent rungs stay live everywhere. The parameter spelling is a per-
    # contract mapping, not a reason to answer false. This stays a verb
    # rather than a constant because it is a CAPABILITY question: a harness that
    # cannot dispatch must answer false and fall back to the inline rung.
    harness="$(detect)" || exit $?
    case "$harness" in
      claude|opencode|adk|codex) echo "true" ;;
      *) echo "false" ;;
    esac
    ;;
  entrypoint)
    entrypoint
    ;;
  headless)
    headless
    ;;
  attended|attended-reason)
    attended="false"
    if [[ "${LOOP_SPEC_NON_INTERACTIVE:-}" == "1" || "${LOOP_SPEC_EXECUTION_PROFILE:-}" == "headless" ]]; then
      reason="headless/operator"
    elif [[ "$(entrypoint_headless)" == "true" ]]; then
      reason="headless/$(entrypoint)"
    elif [[ "${LOOP_SPEC_EXECUTION_PROFILE:-}" == "interactive" ]]; then
      attended="true"; reason="interactive-profile"
    else
      harness="$(detect)" || exit $?
      ep="$(entrypoint)"
      if [[ "$harness" != "claude" ]]; then
        attended="true"; reason="bridge/$harness"
      elif [[ "$ATTENDED_ENTRYPOINTS" == *" $ep "* ]]; then
        attended="true"; reason="attended/$ep"
      else
        reason="unproven/$ep"
      fi
    fi
    if [[ "$cmd" == "attended" ]]; then echo "$attended"; else echo "$reason"; fi
    ;;
  session-layer|session-layer-reason)
    layer="in-harness"
    case "${LOOP_SPEC_SESSION_LAYER:-}" in
      1) layer="session"; reason="operator-enabled" ;;
      0) reason="operator-disabled" ;;
      *)
        cli="$(detect)" || exit $?
        if [[ "$(headless)" != "true" ]]; then
          reason="attended/$(entrypoint)"
        elif [[ ! -f "$SESSION_PROFILES/$cli.toml" ]]; then
          reason="no-profile/$cli"
        elif ! command -v "$cli" >/dev/null 2>&1; then
          reason="cli-missing/$cli"
        elif ! python3 -c 'import tomllib' >/dev/null 2>&1; then
          reason="python-below-3.11"
        else
          layer="session"
          reason="headless/$cli"
        fi
        ;;
    esac
    if [[ "$cmd" == "session-layer" ]]; then echo "$layer"; else echo "$reason"; fi
    ;;
  loop-runtime|loop-runtime-reason)
    runtime="false"
    reason="unproven-runtime"
    case "${LOOP_SPEC_LOOP_RUNTIME:-}" in
      # Absolute: the integrator asserting their wrapper can (or cannot) hold a
      # foreground call open. Outranks every probe below, including the stamp.
      1) runtime="true"; reason="operator-enabled" ;;
      0) runtime="false"; reason="operator-disabled" ;;
      *)
        if [[ "${LOOP_SPEC_NON_INTERACTIVE:-}" == "1" ]]; then
          runtime="false"
          reason="headless/non-interactive"
        elif [[ "$(entrypoint_headless)" == "true" ]]; then
          # Proven headless by the harness itself. Deliberately checked BEFORE
          # EXECUTION_PROFILE: a stamped `claude -p` / SDK job has no persistent
          # runtime no matter what an inherited `interactive` export claims.
          runtime="false"
          reason="headless/$(entrypoint)"
        else
          case "${LOOP_SPEC_EXECUTION_PROFILE:-}" in
            interactive) runtime="true"; reason="interactive-profile" ;;
            headless) runtime="false"; reason="headless/non-interactive" ;;
          esac
        fi
        ;;
    esac
    if [[ "$cmd" == "loop-runtime" ]]; then echo "$runtime"; else echo "$reason"; fi
    ;;
  protected-path)
    shift
    protected_path "$@"
    ;;
  *)
    echo "harness.sh: unknown command '${cmd}' (detect|cli|subagents|entrypoint|headless|attended|attended-reason|loop-runtime|loop-runtime-reason|session-layer|session-layer-reason|protected-path)" >&2
    exit 2
    ;;
esac
