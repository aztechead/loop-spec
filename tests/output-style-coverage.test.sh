#!/usr/bin/env bash
# Output-style coverage: mid-turn silence binds in the Claude Code output-style
# slot, not in a hook or CLAUDE.md. A paragraph of "be concise" in those other
# places does not shorten chat; force-for-plugin on output-styles/loop-spec.md does.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
PASS=0
FAIL=0

STYLE="output-styles/loop-spec.md"

ok() { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

if [[ -f "$STYLE" ]]; then
  ok "output-styles/loop-spec.md exists"
else
  bad "output-styles/loop-spec.md missing"
fi

for needle in \
  "force-for-plugin: true" \
  "keep-coding-instructions: true" \
  "Emit no text between tool calls" \
  "Never compress" \
  "one chat message per turn"; do
  if grep -Fq "$needle" "$STYLE"; then
    ok "style carries: $needle"
  else
    bad "style missing: $needle"
  fi
done

# The finding: the same instruction in a hook does not bind. Pin that we did
# not copy mid-turn silence into SessionStart injectors.
if grep -RFq "Emit no text between tool calls" hooks; then
  bad "hooks copied mid-turn silence out of the output-style slot"
else
  ok "hooks do not carry mid-turn silence"
fi

if grep -Fq "output-styles/loop-spec.md" skills/shared/report-style.md &&
   grep -Fq "force-for-plugin" skills/shared/report-style.md; then
  ok "report-style names the Claude slot"
else
  bad "report-style.md no longer names output-styles/loop-spec.md as the Claude slot"
fi

if grep -Fq "output-styles/loop-spec.md" skills/shared/claude-harness.md &&
   grep -Fq "force-for-plugin" skills/shared/claude-harness.md; then
  ok "claude-harness names the output style"
else
  bad "claude-harness.md no longer names the output style"
fi

# Peer harnesses have no slot; they must say so rather than pretend the Claude
# file loads.
for f in skills/shared/opencode-harness.md skills/shared/codex-harness.md \
         skills/shared/adk-harness.md; do
  if grep -Fq "no output-style slot" "$f"; then
    ok "$f records the missing slot"
  else
    bad "$f does not say it has no output-style slot"
  fi
done

# Contributor rules name a moment, not a preference.
if grep -Fq "When you add or edit a file under" CLAUDE.md &&
   grep -Fq "When you would put mid-turn chatter" CLAUDE.md; then
  ok "CLAUDE.md philosophy bullets name a moment"
else
  bad "CLAUDE.md lost trigger-shaped philosophy bullets"
fi

if grep -Fq "stop at the first rung that holds" skills/shared/laziness-ladder.md &&
   grep -Fq "Do not narrate the rungs" skills/shared/laziness-ladder.md; then
  ok "laziness-ladder compact directive is a stop-at-first-rung nudge"
else
  bad "laziness-ladder.md lost the stop-at-first-rung nudge"
fi

if grep -Fq "When you are about to write or edit code this session" \
     hooks/team/simplicity-inject.sh; then
  ok "simplicity-inject names the write-code moment"
else
  bad "simplicity-inject.sh lost the write-code moment"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
