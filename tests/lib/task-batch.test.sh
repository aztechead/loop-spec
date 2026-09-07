#!/usr/bin/env bash
# Tests for lib/task-batch.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/lib/task-batch.sh"
PASS=0
FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $name"; ((PASS++)) || true
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"; ((FAIL++)) || true
  fi
}

WORK="${TMPDIR:-/tmp}/task-batch-test.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"

cat > "$WORK/collapse.json" <<'EOF'
[
  {"id":"task-001","brief":"rename in a","files":["a.sh"],"blockedBy":[],
   "verifyCommand":"bash -n a.sh","acceptanceCriteria":["ok"],"batchGroup":"rename"},
  {"id":"task-002","brief":"rename in b","files":["b.sh"],"blockedBy":[],
   "verifyCommand":"bash -n a.sh","acceptanceCriteria":["ok"],"batchGroup":"rename"},
  {"id":"task-003","brief":"other","files":["c.sh"],"blockedBy":[],
   "verifyCommand":"true","acceptanceCriteria":["ok"]}
]
EOF
out=$(bash "$SCRIPT" collapse "$WORK/collapse.json")
check "collapse count" "2" "$(jq 'length' <<<"$out")"
check "keeps first id" "task-001" "$(jq -r '.[0].id' <<<"$out")"
check "unions files" "a.sh,b.sh" "$(jq -r '.[0].files | join(",")' <<<"$out")"
check "memberIds order" "task-001,task-002" "$(jq -r '.[0].memberIds | join(",")' <<<"$out")"
check "ungrouped passes through" "task-003" "$(jq -r '.[1].id' <<<"$out")"

cat > "$WORK/no-hint.json" <<'EOF'
[
  {"id":"task-001","files":["a.sh"],"blockedBy":[],"verifyCommand":"true","acceptanceCriteria":["ok"]},
  {"id":"task-002","files":["b.sh"],"blockedBy":[],"verifyCommand":"true","acceptanceCriteria":["ok"]}
]
EOF
out=$(bash "$SCRIPT" collapse "$WORK/no-hint.json")
check "no hint does not collapse" "2" "$(jq 'length' <<<"$out")"

cat > "$WORK/blocked.json" <<'EOF'
[
  {"id":"task-001","files":["a.sh"],"blockedBy":[],"verifyCommand":"true",
   "acceptanceCriteria":["ok"],"batchGroup":"g"},
  {"id":"task-002","files":["b.sh"],"blockedBy":["task-009"],"verifyCommand":"true",
   "acceptanceCriteria":["ok"],"batchGroup":"g"}
]
EOF
out=$(bash "$SCRIPT" collapse "$WORK/blocked.json")
check "blockedBy outside group does not collapse" "2" "$(jq 'length' <<<"$out")"

cat > "$WORK/inbound.json" <<'EOF'
[
  {"id":"task-001","files":["a.sh"],"blockedBy":[],"verifyCommand":"true",
   "acceptanceCriteria":["ok"],"batchGroup":"g"},
  {"id":"task-002","files":["b.sh"],"blockedBy":[],"verifyCommand":"true",
   "acceptanceCriteria":["ok"],"batchGroup":"g"},
  {"id":"task-003","files":["c.sh"],"blockedBy":["task-002"],"verifyCommand":"true",
   "acceptanceCriteria":["ok"]}
]
EOF
out=$(bash "$SCRIPT" collapse "$WORK/inbound.json")
check "outside task waiting on an erased member does not collapse" "3" "$(jq 'length' <<<"$out")"
check "erased member survives the refusal" "task-002" "$(jq -r '.[1].id' <<<"$out")"

cat > "$WORK/inbound-first.json" <<'EOF'
[
  {"id":"task-001","files":["a.sh"],"blockedBy":[],"verifyCommand":"true",
   "acceptanceCriteria":["ok"],"batchGroup":"g"},
  {"id":"task-002","files":["b.sh"],"blockedBy":[],"verifyCommand":"true",
   "acceptanceCriteria":["ok"],"batchGroup":"g"},
  {"id":"task-003","files":["c.sh"],"blockedBy":["task-001"],"verifyCommand":"true",
   "acceptanceCriteria":["ok"]}
]
EOF
out=$(bash "$SCRIPT" collapse "$WORK/inbound-first.json")
check "edge to the surviving id still collapses" "2" "$(jq 'length' <<<"$out")"

cat > "$WORK/verify.json" <<'EOF'
[
  {"id":"task-001","files":["a.sh"],"blockedBy":[],"verifyCommand":"bash -n a.sh",
   "acceptanceCriteria":["ok"],"batchGroup":"g"},
  {"id":"task-002","files":["b.sh"],"blockedBy":[],"verifyCommand":"bash -n b.sh",
   "acceptanceCriteria":["ok"],"batchGroup":"g"}
]
EOF
out=$(bash "$SCRIPT" collapse "$WORK/verify.json")
check "verifyCommand mismatch does not collapse" "2" "$(jq 'length' <<<"$out")"

cat > "$WORK/overlap.json" <<'EOF'
[
  {"id":"task-001","files":["shared.sh"],"blockedBy":[],"verifyCommand":"true",
   "acceptanceCriteria":["ok"],"batchGroup":"g"},
  {"id":"task-002","files":["shared.sh"],"blockedBy":[],"verifyCommand":"true",
   "acceptanceCriteria":["ok"],"batchGroup":"g"}
]
EOF
out=$(bash "$SCRIPT" collapse "$WORK/overlap.json")
check "overlapping files do not collapse" "2" "$(jq 'length' <<<"$out")"

ec=0; bash "$SCRIPT" >/dev/null 2>&1 || ec=$?
check "usage exits 2" "2" "$ec"

echo ""

# A linear chain of local-verify tasks merges into its head; a real run (plan, a test
# suite, a script) keeps its own seat; a pinned tier stops the chain; the head of a
# doc/config-only chain is tiered mechanical.
cat > "$WORK/chain.json" <<'EOF'
[
  {"id":"task-001","subject":"root","files":["root.hcl"],"blockedBy":[],"verifyCommand":"grep -qF 'expose = true' root.hcl","acceptanceCriteria":["a"]},
  {"id":"task-002","subject":"unit","files":["site/terragrunt.hcl"],"blockedBy":["task-001"],"verifyCommand":"grep -q include site/terragrunt.hcl && test -f site/terragrunt.hcl","acceptanceCriteria":["b"]},
  {"id":"task-003","subject":"plan","files":["site/main.tf"],"blockedBy":["task-002"],"verifyCommand":"terragrunt plan --no-color | grep -qF 'No changes.'","acceptanceCriteria":["c"]},
  {"id":"task-004","subject":"readme","files":["README.md"],"blockedBy":["task-003"],"verifyCommand":"grep -q Bootstrap README.md","acceptanceCriteria":["d"]},
  {"id":"task-005","subject":"script","files":["bin/x.sh"],"blockedBy":["task-004"],"verifyCommand":"bash -n bin/x.sh","acceptanceCriteria":["e"],"metadata":{"modelTier":"standard"}},
  {"id":"task-006","subject":"run","files":["bin/y.py"],"blockedBy":["task-005"],"verifyCommand":"python3 bin/y.py","acceptanceCriteria":["f"]}
]
EOF
out=$(bash "$SCRIPT" collapse "$WORK/chain.json")
check "chain: two grep tasks merge into the head" "task-001,task-002" "$(jq -r '.[0].memberIds | join(",")' <<<"$out")"
check "chain: merged files are the union" "root.hcl,site/terragrunt.hcl" "$(jq -r '.[0].files | join(",")' <<<"$out")"
check "chain: verifies join with &&" "1" "$(jq -r '.[0].verifyCommand' <<<"$out" | grep -c '^(grep -qF .*) && (grep -q include')"
check "chain: criteria concatenate" "a,b" "$(jq -r '.[0].acceptanceCriteria | join(",")' <<<"$out")"
check "chain: a plan verify keeps its seat and waits on the head" "task-001" "$(jq -r '.[] | select(.id == "task-003") | .blockedBy[0]' <<<"$out")"
check "chain: a pinned tier stops the merge" "task-004,task-005,task-006" "$(jq -r '.[2:] | map(.id) | join(",")' <<<"$out")"
check "tier: config-only local-verify head is mechanical" "mechanical" "$(jq -r '.[0].metadata.modelTier' <<<"$out")"
check "tier: a plan verify is not mechanical" "null" "$(jq -r '.[] | select(.id == "task-003") | .metadata.modelTier' <<<"$out")"
check "tier: an explicit tier is kept" "standard" "$(jq -r '.[] | select(.id == "task-005") | .metadata.modelTier' <<<"$out")"
check "tier: running a script is a real run" "null" "$(jq -r '.[] | select(.id == "task-006") | .metadata.modelTier' <<<"$out")"
out=$(LOOP_SPEC_TASK_BATCH_CHAIN_FILES=1 bash "$SCRIPT" collapse "$WORK/chain.json")
check "chain: the file cap holds" "6" "$(jq 'length' <<<"$out")"
out=$(LOOP_SPEC_TASK_BATCH_AUTO=0 bash "$SCRIPT" collapse "$WORK/chain.json")
check "kill switch: nothing merges or tiers" "6,null" "$(jq -r '"\(length),\(.[0].metadata.modelTier // null)"' <<<"$out")"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
