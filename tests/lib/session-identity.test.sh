#!/usr/bin/env bash
# Offline integration coverage for native payload identity reaching the driver.
set -euo pipefail
. "$(dirname "$0")/cycle-driver.common.sh"

resolved="$(LOOP_SPEC_SESSION_ID=canonical CLAUDE_CODE_SESSION_ID=legacy \
  LOOP_SPEC_IDENTITY_INPUT='{"session_id":"native"}' python3 "$REPO_ROOT/lib/session_identity.py")"
check "canonical identity outranks legacy and payload" "canonical" "$resolved"
resolved="$(env -u LOOP_SPEC_SESSION_ID CLAUDE_CODE_SESSION_ID=legacy \
  LOOP_SPEC_IDENTITY_INPUT='{"session_id":"native"}' python3 "$REPO_ROOT/lib/session_identity.py")"
check "legacy identity outranks native payload" "legacy" "$resolved"
resolved="$(env -u LOOP_SPEC_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID \
  LOOP_SPEC_IDENTITY_INPUT='{"session_id":"native"}' python3 "$REPO_ROOT/lib/session_identity.py")"
check "native payload supplies missing identity" "native" "$resolved"

REPO="$(new_repo identity)"
SESSION=native-a AUTONOMOUS=1 out="$(drv begin --dir "$REPO" -- autonomous identity probe 2>/dev/null)"
FD="$(jq -r '.featureDir' <<<"$out")"
ROOT="$REPO"
mkdir -p "$ROOT/docs/loop-spec/features/$(jq -r '.slug' "$FD/feature.json")"
cp "$REPO_ROOT/tests/fixtures/minimal-SPEC.md" "$ROOT/docs/loop-spec/features/$(jq -r '.slug' "$FD/feature.json")/SPEC.md"
initial="$(shasum "$FD/feature.json" | awk '{print $1}')"
ec=0; (cd "$ROOT" && env -u LOOP_SPEC_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID \
  LOOP_SPEC_HARNESS=codex LOOP_SPEC_TEAMS_MODE=none LOOP_SPEC_WORKFLOWS_AVAILABLE=0 \
  LOOP_SPEC_CHECKPOINT_PR=0 bash "$SCRIPT" next --feature-dir "$FD" >/dev/null 2>&1) || ec=$?
check "anonymous initial next is refused" "2" "$ec"
check "anonymous initial next leaves state unchanged" "$initial" "$(shasum "$FD/feature.json" | awk '{print $1}')"
(cd "$ROOT" && SESSION=native-a AUTONOMOUS=1 drv next --feature-dir "$FD" >/dev/null)

# The native payload is converted to the actual Bash command by the Claude
# adapter; no legacy session variable is present in the driver process.
payload="$(jq -cn --arg cmd "bash '$SCRIPT' next --feature-dir '$FD' --returned-from spec" \
  '{tool_name:"Bash",tool_input:{command:$cmd},session_id:"native-a",cwd:"'"$ROOT"'"}')"
updated="$(printf '%s' "$payload" | bash "$REPO_ROOT/hooks/team/session-env-inject.sh")"
command="$(jq -r '.hookSpecificOutput.updatedInput.command' <<<"$updated")"
env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID bash -c "cd '$ROOT' && $command" >/dev/null
check "native payload writes real handoff identity" "native-a" "$(jq -r '.handoffSession.id' "$FD/feature.json")"
before="$(shasum "$FD/feature.json" | awk '{print $1}')"
ec=0; (cd "$ROOT" && env -u LOOP_SPEC_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID \
  bash "$SCRIPT" next --feature-dir "$FD" >/dev/null 2>&1) || ec=$?
check "anonymous driver cannot consume handoff" "2" "$ec"
check "anonymous handoff refusal leaves state byte-identical" "$before" "$(shasum "$FD/feature.json" | awk '{print $1}')"

same="$(jq -cn --arg cwd "$ROOT" '{tool_name:"Bash",tool_input:{command:"echo blocked"},session_id:"native-a",cwd:$cwd}')"
ec=0; CLAUDE_PROJECT_DIR="$ROOT" printf '%s' "$same" | CLAUDE_PROJECT_DIR="$ROOT" bash "$REPO_ROOT/hooks/team/phase-handoff-guard.sh" >/dev/null 2>&1 || ec=$?
check "same native identity is denied by durable handoff" "2" "$ec"
agent="$(jq -cn --arg cwd "$ROOT" '{tool_name:"Agent",tool_input:{description:"continue"},session_id:"native-a",cwd:$cwd}')"
ec=0; CLAUDE_PROJECT_DIR="$ROOT" printf '%s' "$agent" | CLAUDE_PROJECT_DIR="$ROOT" bash "$REPO_ROOT/hooks/team/phase-handoff-guard.sh" >/dev/null 2>&1 || ec=$?
check "same native identity denies Agent too" "2" "$ec"
fresh="$(jq -cn --arg cwd "$ROOT" '{tool_name:"Bash",tool_input:{command:"echo fresh"},session_id:"native-b",cwd:$cwd}')"
ec=0; CLAUDE_PROJECT_DIR="$ROOT" printf '%s' "$fresh" | CLAUDE_PROJECT_DIR="$ROOT" bash "$REPO_ROOT/hooks/team/phase-handoff-guard.sh" >/dev/null 2>&1 || ec=$?
check "fresh native identity is allowed" "0" "$ec"
resume_payload="$(jq -cn --arg cmd "bash '$SCRIPT' next --feature-dir '$FD'" \
  '{tool_name:"Bash",tool_input:{command:$cmd},session_id:"native-b",cwd:"'"$ROOT"'"}')"
resume_updated="$(printf '%s' "$resume_payload" | bash "$REPO_ROOT/hooks/team/session-env-inject.sh")"
resume_command="$(jq -r '.hookSpecificOutput.updatedInput.command' <<<"$resume_updated")"
res="$(cd "$ROOT" && env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID \
  LOOP_SPEC_HARNESS=codex LOOP_SPEC_TEAMS_MODE=none LOOP_SPEC_WORKFLOWS_AVAILABLE=0 \
  LOOP_SPEC_CHECKPOINT_PR=0 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
  bash -c "$resume_command" 2>/dev/null)"
check "fresh native driver resumes the handoff" "NEXT phase=plan" "${res:0:15}"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
