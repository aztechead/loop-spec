#!/usr/bin/env bash
# run.sh - Launch the PAID, LIVE outcome eval for loop-spec. This is not a test.
#
# It runs real cycles against a real model and spends money (roughly USD 1-3 per task on
# haiku, 3-10 on sonnet, as of 6.1). tests/run-all.sh never registers it, and an agent
# working in this repo must not run it unless the user asked for a live eval in the
# current session (CLAUDE.md). Both guards below exist so a stray invocation costs nothing.
#
# Usage:
#   LOOP_SPEC_EVAL_LIVE=1 bash evals/run.sh --model sonnet --confirm-spend \
#       [--tasks fib-cli,slugify-bug] [--parallel 5] [--budget-usd 20] [--run-id NAME]
#
# Results: evals/results/<run-id>/<task>.json and summary.md (commit these).
# Workspaces: evals/.runs/<run-id>/ (ignored; delete when done).
# Exit: 0 every task produced a result; 1 a task crashed the driver; 2 refused or bad args.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${LOOP_SPEC_EVAL_LIVE:-}" != "1" ]]; then
  echo "run.sh: refusing. This eval spends money. Read evals/README.md, then set LOOP_SPEC_EVAL_LIVE=1 and pass --confirm-spend." >&2
  exit 2
fi
exec python3 "$SCRIPT_DIR/eval_run.py" "$@"
