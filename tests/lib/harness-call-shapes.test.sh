#!/usr/bin/env bash
# Lint every skill/agent/shared doc against the recorded harness call contracts
# (skills/shared/harness-call-contracts.md). A call that "reads right" but fails the
# real tool schema silently downgrades the cycle at runtime — this suite keeps the
# instruction corpus honest without needing a live harness.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
PASS=0
FAIL=0

check() {
  local name="$1" cond="$2" detail="${3:-}"
  if [[ "$cond" == "1" ]]; then PASS=$((PASS+1)); echo "PASS: $name"
  else FAIL=$((FAIL+1)); echo "FAIL: $name${detail:+ — $detail}"; fi
}

CORPUS=$(find skills agents -name '*.md' 2>/dev/null)

# 1) Every AskUserQuestion({ block must use the questions:[...] wrapper.
bad=""
for f in $CORPUS; do
  while IFS=: read -r ln _; do
    [[ -z "$ln" ]] && continue
    window=$(sed -n "${ln},$((ln+3))p" "$f")
    echo "$window" | grep -q 'questions:' || bad="$bad $f:$ln"
  done < <(grep -n 'AskUserQuestion({' "$f" 2>/dev/null)
done
check "AskUserQuestion calls use questions:[...] wrapper" "$([[ -z "$bad" ]] && echo 1 || echo 0)" "$bad"

# 2) Bare-string option arrays are invalid (options need {label, description} objects).
bad=$(grep -rn 'options: \["' skills agents --include='*.md' 2>/dev/null | grep -v 'harness-call-contracts' | head -5 || true)
check "no bare-string AskUserQuestion options" "$([[ -z "$bad" ]] && echo 1 || echo 0)" "$bad"

bad=$(grep -rnE 'header: *"[^"]{13,}"' skills agents --include='*.md' 2>/dev/null | head -5 || true)
check "AskUserQuestion headers stay within 12 characters" "$([[ -z "$bad" ]] && echo 1 || echo 0)" "$bad"

bad=$(grep -rn 'subagentBrief' skills/checking-gates/SKILL.md skills/specifying-gates/SKILL.md 2>/dev/null | head -5 || true)
check "gate skills use canonical dispatchBrief metadata" "$([[ -z "$bad" ]] && echo 1 || echo 0)" "$bad"

# 3) Every Agent({ block must carry the REQUIRED description: within its body.
bad=""
for f in $CORPUS; do
  while IFS=: read -r ln _; do
    [[ -z "$ln" ]] && continue
    window=$(sed -n "${ln},$((ln+12))p" "$f")
    # Only lint call templates (they carry prompt); prose shorthand still must
    # name description, checked by the shorthand grep below.
    if echo "$window" | grep -q 'prompt'; then
      echo "$window" | grep -q 'description' || bad="$bad $f:$ln"
    fi
  done < <(grep -n 'Agent({' "$f" 2>/dev/null)
done
check "Agent calls carry required description:" "$([[ -z "$bad" ]] && echo 1 || echo 0)" "$bad"

# 3b) The Agent tool's `model` is an alias enum: `Agent({model: "inherit"})` fails with
# InputValidationError (live-probed 2026-08-11). Inheritance is expressed by OMITTING the
# key, so a template that spells the placeholder out is a broken call, not a portable one.
bad=$(grep -rn 'model: *"inherit"' skills agents --include='*.md' 2>/dev/null \
  | grep -v 'harness-call-contracts' | head -5 || true)
check "no literal model: \"inherit\" in Agent call templates" "$([[ -z "$bad" ]] && echo 1 || echo 0)" "$bad"
grep -qF 'ALIAS ENUM — "inherit" and literal IDs REJECTED' \
  skills/shared/harness-call-contracts.md && v=1 || v=0
check "contract doc records the Agent model alias enum" "$v"

# Dynamic placeholders are just as dangerous as a quoted literal: when the
# default resolves to inherit, `model: feature.models.role` emits the rejected
# value. The startup probe is the one exception because it first filters its
# loop input to the four aliases below.
bad=$(grep -rnE 'model: *(feature\.models\.|models\.|model_mapper|mapper_model)' \
  skills agents --include='*.md' 2>/dev/null | head -5 || true)
check "Agent templates do not emit dynamic model placeholders" \
  "$([[ -z "$bad" ]] && echo 1 || echo 0)" "$bad"

PROBES=skills/cycle/references/startup-probes.md
grep -qF '[[ "$agent_probe_models" == "[]" ]] && skip_probe=true' "$PROBES" \
  && v=1 || v=0
check "inherit-only startup skips every Agent model probe" "$v"
grep -qF 'for model_selector in agent_probe_models:' "$PROBES" \
  && grep -qF 'feature-init.sh" agent-probe-models' "$PROBES" \
  && v=1 || v=0
check "startup model probes iterate only over Agent aliases" "$v"

# 4) TaskList takes no status/filter arguments.
bad=$(grep -rn 'TaskList({status' skills agents --include='*.md' 2>/dev/null | grep -v 'harness-call-contracts' | head -5 || true)
check "no TaskList({status: ...}) filter args" "$([[ -z "$bad" ]] && echo 1 || echo 0)" "$bad"

# 5) Every TaskCreate({ block must carry the REQUIRED description:.
bad=""
for f in $CORPUS; do
  while IFS=: read -r ln _; do
    [[ -z "$ln" ]] && continue
    window=$(sed -n "${ln},$((ln+6))p" "$f")
    echo "$window" | grep -q 'description:' || bad="$bad $f:$ln"
  done < <(grep -n 'TaskCreate({' "$f" 2>/dev/null)
done
check "TaskCreate calls carry required description:" "$([[ -z "$bad" ]] && echo 1 || echo 0)" "$bad"

# 6) Shipped dispatch examples stay model-portable; explicit IDs belong to
# operator configuration, not built-in role defaults.
bad=$(grep -rnE 'model: "?claude-' skills agents --include='*.md' 2>/dev/null | grep -v 'harness-call-contracts\|model-matrix' | head -5 || true)
check "no pinned model IDs in default dispatch examples" "$([[ -z "$bad" ]] && echo 1 || echo 0)" "$bad"

# 7) Contract doc exists and records the verification method.
check "harness-call-contracts.md present" "$([[ -f skills/shared/harness-call-contracts.md ]] && echo 1 || echo 0)"
grep -q 'Verification method' skills/shared/harness-call-contracts.md && v=1 || v=0
check "contract doc records verification method" "$v"
grep -q 'code.claude.com/docs/en/sub-agents' skills/shared/model-matrix.md && v=1 || v=0
check "contract docs cite current Claude Code model inheritance" "$v"
grep -qF 'mode: "acceptEdits" | ... | "plan",      // deprecated and ignored since CC 2.1.212' \
  skills/shared/harness-call-contracts.md && v=1 || v=0
check "contract doc records ignored Agent mode" "$v"
grep -qF 'in-process teammate' skills/shared/harness-call-contracts.md \
  && grep -qF 'lib/implicit-team-model.sh' skills/shared/implicit-team-mode.md \
  && v=1 || v=0
check "contract docs record named implicit-team model inheritance" "$v"

# 8) No run_in_background anywhere in skills/ agents/ *.md
#    (harness-call-contracts.md is excluded — it documents the portability rule).
bad=$(grep -rn 'run_in_background' skills agents --include='*.md' 2>/dev/null \
        | grep -v 'harness-call-contracts' | head -5 || true)
check "no run_in_background in skill/agent corpus" "$([[ -z "$bad" ]] && echo 1 || echo 0)" "$bad"

# 8b) Waiting on a background Agent is dispatch-then-stop, never a fake question.
#     Live /cycle invented AskUserQuestion({header: wait, question: "not a real
#     question", options: n/a / n/a2 / Type something}) on SPEC scout fan-out,
#     every PLAN/DISCUSS TeammateIdle join, and the pruning pass — not once.
grep -qF 'Never AskUserQuestion as a wait' \
  skills/shared/harness-call-contracts.md && v=1 || v=0
check "contract doc forbids AskUserQuestion as a wait" "$v"
grep -qF 'not a real question' skills/shared/harness-call-contracts.md && v=1 || v=0
check "contract doc names the dummy-question tell" "$v"

bad=$(grep -rn 'Wait for `TeammateIdle`' skills --include='*.md' || true)
check "no lead Wait-for-TeammateIdle (stop-then-resume instead)" \
  "$([[ -z "$bad" ]] && echo 1 || echo 0)" "$bad"

wait_missing=""
for f in \
  skills/spec/SKILL.md \
  skills/plan/SKILL.md \
  skills/discuss/SKILL.md \
  skills/execute/SKILL.md \
  skills/verify/SKILL.md \
  skills/iterate/SKILL.md \
  skills/deliver/SKILL.md \
  skills/map-codebase/SKILL.md \
  skills/shared/critique-gate-protocol.md \
  skills/shared/no-teams-fallback.md \
  skills/shared/subagent-concurrency.md \
  skills/shared/execute-subagent.md \
  skills/shared/execute-loop-fleet.md \
  skills/cycle/references/startup-probes.md \
  skills/cycle/references/codebase-map-bootstrap.md \
  skills/cycle/references/phase-activate.md \
  skills/execute/references/team-rung-protocol.md \
  skills/plan/references/patterns-bootstrap.md \
  skills/verify/references/workspace-mode.md
do
  grep -qiF 'never AskUserQuestion as a wait' "$f" \
    || wait_missing="$wait_missing $f"
done
check "every Agent-joining phase forbids AskUserQuestion as a wait" \
  "$([[ -z "$wait_missing" ]] && echo 1 || echo 0)" "$wait_missing"
grep -qF 'placeholder-question-guard.sh' hooks/hooks.json \
  && grep -qF '"matcher": "AskUserQuestion"' hooks/hooks.json \
  && v=1 || v=0
check "hooks.json registers the placeholder-question PreToolUse guard" "$v"
grep -qF 'placeholder-question-guard.sh' skills/shared/harness-call-contracts.md \
  && v=1 || v=0
check "contract doc names the placeholder-question hook" "$v"

# 8adeb32 replaced the only ITERATE AskUserQuestion({ questions: [...] }) with
# prose shorthand; the model then invented the dummy wait shape. Call-contract
# examples that the harness actually executes must stay as JSON.
grep -qF 'AskUserQuestion({' skills/iterate/SKILL.md \
  && grep -qF 'header: "Re-open SPEC"' skills/iterate/SKILL.md \
  && grep -qF 'questions: [{' skills/iterate/SKILL.md && v=1 || v=0
check "ITERATE spec-rewind gate is a questions-wrapper call" "$v"
grep -qF 'AskUserQuestion({' skills/execute/references/team-rung-protocol.md \
  && grep -qF 'header: "Plan gap"' skills/execute/references/team-rung-protocol.md \
  && grep -qF 'questions: [{' skills/execute/references/team-rung-protocol.md && v=1 || v=0
check "EXECUTE plan-adherence gate is a questions-wrapper call" "$v"
grep -qF 'AskUserQuestion({' skills/spec/references/interview-prompts.md \
  && grep -qF 'header: "Spec gate"' skills/spec/references/interview-prompts.md \
  && grep -qF 'header: "Max rounds"' skills/spec/references/interview-prompts.md \
  && grep -qF 'questions: [{' skills/spec/references/interview-prompts.md && v=1 || v=0
check "SPEC gate prompts are questions-wrapper calls" "$v"
grep -E '^allowed-tools:' skills/verify/SKILL.md | grep -q AskUserQuestion && v=0 || v=1
check "VERIFY allowed-tools omit AskUserQuestion" "$v"
grep -E '^allowed-tools:' skills/deliver/SKILL.md | grep -q AskUserQuestion && v=0 || v=1
check "DELIVER allowed-tools omit AskUserQuestion" "$v"

# 8c) Live /cycle: bash sleep-polls (120s PATTERNS join, 600s map bootstrap)
#     froze the session between DISCUSS and PLAN. Check once, then fallback.
grep -qF 'Never `sleep` to join a background Agent' \
  skills/shared/harness-call-contracts.md && v=1 || v=0
check "contract doc forbids sleep-poll joins" "$v"
bad=$(grep -rnE 'sleep \$interval' skills --include='*.md' || true)
check "no sleep-poll join of background Agents" \
  "$([[ -z "$bad" ]] && echo 1 || echo 0)" "$bad"
grep -qF 'check once' skills/plan/SKILL.md \
  && grep -qiF 'never sleep' skills/plan/SKILL.md \
  && grep -qiF 'Do not sleep' skills/discuss/SKILL.md \
  && v=1 || v=0
check "PLAN prefetch and DISCUSS bootstrap join without sleep" "$v"

# 9) For every SendMessage({ occurrence, the 4-line window must NOT contain body:
#    (harness-call-contracts.md excluded — it documents the invalid param).
bad=""
for f in $CORPUS; do
  [[ "$f" == *harness-call-contracts* ]] && continue
  while IFS=: read -r ln _; do
    [[ -z "$ln" ]] && continue
    window=$(sed -n "${ln},$((ln+3))p" "$f")
    echo "$window" | grep -q 'body:' && bad="$bad $f:$ln"
  done < <(grep -n 'SendMessage({' "$f" 2>/dev/null)
done
check "SendMessage calls do not use invalid body: param" "$([[ -z "$bad" ]] && echo 1 || echo 0)" "$bad"

# 10) For every SendMessage({ occurrence, the 4-line window MUST contain message
#     (harness-call-contracts.md excluded).
bad=""
for f in $CORPUS; do
  [[ "$f" == *harness-call-contracts* ]] && continue
  while IFS=: read -r ln _; do
    [[ -z "$ln" ]] && continue
    window=$(sed -n "${ln},$((ln+3))p" "$f")
    echo "$window" | grep -q 'message' || bad="$bad $f:$ln"
  done < <(grep -n 'SendMessage({' "$f" 2>/dev/null)
done
check "SendMessage calls carry message param" "$([[ -z "$bad" ]] && echo 1 || echo 0)" "$bad"

# 11) OpenCode's current task contract includes resumable child sessions.
grep -qF '{description, prompt, subagent_type, task_id?, command?}' \
  skills/shared/harness-call-contracts.md && v=1 || v=0
check "OpenCode task contract records task_id" "$v"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
