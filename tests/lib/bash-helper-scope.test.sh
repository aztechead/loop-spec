#!/usr/bin/env bash
# Pin local-scope discipline in pr-delivery.sh and deliver.sh helpers.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0
FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"; FAIL=$((FAIL + 1))
  fi
}

# validate_pr_snapshot must not assign script-level identity fields.
hits="$(python3 - "$REPO_ROOT/lib/pr-delivery.sh" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
match = re.search(r"^validate_pr_snapshot\(\) \{", text, re.M)
if not match:
    print("MISSING")
    sys.exit(0)
start = match.start()
rest = text[start:]
depth = 0
end = None
for i, ch in enumerate(rest):
    if ch == "{":
        depth += 1
    elif ch == "}":
        depth -= 1
        if depth == 0:
            end = i
            break
body = rest[: end + 1] if end is not None else rest
assign = re.findall(r"^(?:is_draft|pr_number|pr_url|head_sha)=", body, re.M)
print(len(assign))
PY
)"
check "validate_pr_snapshot does not assign identity fields" "0" "$hits"

# apply_pr_snapshot is the helper that assigns those fields from the snapshot file.
hits="$(python3 - "$REPO_ROOT/lib/pr-delivery.sh" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
match = re.search(r"^apply_pr_snapshot\(\) \{", text, re.M)
body = text[match.start(): match.start() + 400]
need = ("pr_number=", "pr_url=", "head_sha=", "is_draft=")
print(sum(1 for n in need if n in body))
PY
)"
check "apply_pr_snapshot assigns all four identity fields" "4" "$hits"

# refresh_remote_sha prints; it does not assign remote_sha.
hits="$(python3 - "$REPO_ROOT/lib/pr-delivery.sh" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
match = re.search(r"^refresh_remote_sha\(\) \{", text, re.M)
rest = text[match.start():]
depth = 0
for i, ch in enumerate(rest):
    if ch == "{":
        depth += 1
    elif ch == "}":
        depth -= 1
        if depth == 0:
            body = rest[: i + 1]
            break
print(len(re.findall(r"^remote_sha=", body, re.M)))
PY
)"
check "refresh_remote_sha does not assign remote_sha" "0" "$hits"

# observe_readiness_after_refresh prints; it does not assign is_draft.
hits="$(python3 - "$REPO_ROOT/lib/pr-delivery.sh" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
match = re.search(r"^observe_readiness_after_refresh\(\) \{", text, re.M)
rest = text[match.start():]
depth = 0
for i, ch in enumerate(rest):
    if ch == "{":
        depth += 1
    elif ch == "}":
        depth -= 1
        if depth == 0:
            body = rest[: i + 1]
            break
print(len(re.findall(r"^is_draft=", body, re.M)))
PY
)"
check "observe_readiness_after_refresh does not assign is_draft" "0" "$hits"

# Named helpers in deliver.sh declare their parameters local.
hits="$(python3 - "$REPO_ROOT/lib/deliver.sh" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
needed = {
    "invoke_delivery": "local repo_dir=",
    "append_target_failure": "local name=",
    "bound_target_sha": "local name=",
}
missing = 0
for name, needle in needed.items():
    match = re.search(r"^" + re.escape(name) + r"\(\) \{", text, re.M)
    if not match:
        missing += 1
        continue
    rest = text[match.start():]
    depth = 0
    for i, ch in enumerate(rest):
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                body = rest[: i + 1]
                break
    if needle not in body:
        missing += 1
print(missing)
PY
)"
check "deliver.sh helpers declare parameters local" "0" "$hits"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
