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

# The manifest must name the default directory. Omitting the key still scans
# output-styles/ today; naming it keeps the slot loaded if that default moves.
if jq -e '.outputStyles == "./output-styles/"' .claude-plugin/plugin.json >/dev/null; then
  ok "plugin.json names outputStyles ./output-styles/"
else
  bad "plugin.json lost outputStyles ./output-styles/"
fi

# Codex has no output-style slot. Pretending it does would load nothing.
if jq -e 'has("outputStyles")' .codex-plugin/plugin.json >/dev/null; then
  bad ".codex-plugin/plugin.json must not declare outputStyles"
else
  ok "Codex plugin.json does not declare outputStyles"
fi

# A description that only summarizes the skill never fires. Each one must name
# a moment the model can recognize and what to do instead of stalling.
desc_rc=0
desc_out="$(python3 - "$REPO_ROOT" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
WHEN = re.compile(
    r"(?i)(use when|use whenever|use after|when the user|when you |when picking|"
    r"when a |when handing|when cron|when the caller|when the input|"
    r"toggle |give it|feed it|after a |preferred |cycle-internal|invoked by)"
)
NOT = re.compile(
    r"(?i)(not for|do not |does not |doesn.t |never |don.t |cycle-internal)"
)

def description_of(path):
    text = path.read_text(encoding="utf-8")
    m = re.search(r"^---\n(.*?)\n---", text, re.S)
    if not m:
        return None
    fm = m.group(1)
    m2 = re.search(r"^description:\s*(.*)$", fm, re.M)
    if not m2:
        return None
    first = m2.group(1).strip()
    rest = fm[m2.end():]
    if first in (">", ">-", "|", "|-"):
        lines = []
        for line in rest.splitlines():
            if re.match(r"^[A-Za-z0-9_-]+:", line):
                break
            if line.startswith(" ") or line.startswith("\t"):
                lines.append(line.strip())
        return " ".join(x for x in lines if x)
    if (first.startswith('"') and first.endswith('"')) or (
        first.startswith("'") and first.endswith("'")
    ):
        return first[1:-1]
    return first

failed = []
seen = 0
for glob in ("skills/*/SKILL.md", "agents/*.md"):
    for path in sorted(root.glob(glob)):
        if path.name == "README.md":
            continue
        desc = description_of(path)
        seen += 1
        rel = path.relative_to(root)
        if not desc:
            failed.append(f"{rel}: missing description")
            continue
        missing = []
        if not WHEN.search(desc):
            missing.append("moment")
        if not NOT.search(desc):
            missing.append("when-not")
        if missing:
            failed.append(f"{rel}: missing {', '.join(missing)}")
print(f"seen={seen}")
if failed:
    print("\n".join(failed))
    sys.exit(1)
print("ok")
PY
)" || desc_rc=$?

if [[ "$desc_rc" -eq 0 ]] && grep -q '^ok$' <<<"$desc_out"; then
  seen="$(sed -n 's/^seen=//p' <<<"$desc_out" | head -1)"
  ok "skill and agent descriptions name a moment and when-not (n=$seen)"
else
  bad "skill/agent description missing a trigger"
  echo "$desc_out" | grep -v '^seen=' | grep -v '^ok$' | sed 's/^/  /'
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
