#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT/skills/cycle/SKILL.md" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
start = text.index('if [[ "$worktrees_enabled" == "0" ]]')
fallback = text.index("else", start)
end = text.index("fi", fallback)
disabled = text[start:fallback]
enabled = text[fallback:end]

checks = [
    ("disabled branch performs an in-place checkout", 'checkout -b "feat/${slug}"' in disabled),
    ("disabled branch never invokes the worktree helper", "create-feature-worktree" not in disabled),
    ("enabled branch invokes the worktree helper", "create-feature-worktree" in enabled),
]
failures = 0
for name, passed in checks:
    print(("PASS: " if passed else "FAIL: ") + name)
    failures += not passed
print(f"Results: {len(checks) - failures} passed, {failures} failed")
raise SystemExit(1 if failures else 0)
PY
