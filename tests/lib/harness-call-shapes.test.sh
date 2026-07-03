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

# 6) No pinned model IDs in dispatch examples (alias enum only).
bad=$(grep -rnE 'model: "?claude-' skills agents --include='*.md' 2>/dev/null | grep -v 'harness-call-contracts\|model-matrix' | head -5 || true)
check "no pinned model IDs in dispatch examples" "$([[ -z "$bad" ]] && echo 1 || echo 0)" "$bad"

# 7) Contract doc exists and records the verification method.
check "harness-call-contracts.md present" "$([[ -f skills/shared/harness-call-contracts.md ]] && echo 1 || echo 0)"
grep -q 'Verification method' skills/shared/harness-call-contracts.md && v=1 || v=0
check "contract doc records verification method" "$v"

# 8) No run_in_background anywhere in skills/ agents/ *.md
#    (harness-call-contracts.md is excluded — it documents the param as invalid).
bad=$(grep -rn 'run_in_background' skills agents --include='*.md' 2>/dev/null \
        | grep -v 'harness-call-contracts' | head -5 || true)
check "no run_in_background in skill/agent corpus" "$([[ -z "$bad" ]] && echo 1 || echo 0)" "$bad"

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

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
