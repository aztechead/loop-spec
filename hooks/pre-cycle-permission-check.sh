#!/usr/bin/env bash
# Read .loop-spec/runtime.json; if workflowsAvailable=false, print
# /permissions hint. Non-fatal.
set -euo pipefail

RUNTIME=".loop-spec/runtime.json"
if [[ ! -f "$RUNTIME" ]]; then
  exit 0
fi

avail=$(python3 -c "import json,sys; d=json.load(open('$RUNTIME')); print(d.get('workflowsAvailable', False))")
if [[ "$avail" == "True" ]]; then
  exit 0
fi

cat <<'EOF'
[loop-spec] Workflow tool unavailable in this session.
   Fan-out phases (map-codebase, acceptance gate, code-review HARD-GATE) will
   fall back to TeamCreate dispatch. To enable workflow acceleration:

     /permissions
     # add Workflow to allow list, then restart this cycle

   Or set CLAUDE_CODE_DISABLE_WORKFLOWS=1 to silence this notice.
EOF
exit 0
