#!/usr/bin/env bash
# Tests for lib/feature-scan-each.sh — per-repo dispatch for VERIFY scans.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/lib/feature-scan-each.sh"
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

WORK="$(mktemp -d "${TMPDIR:-/tmp}/feature-scan-each-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

SCAN="$WORK/scan.sh"
cat > "$SCAN" <<'SH'
#!/usr/bin/env bash
echo "SCAN ${1:-} ${2:-}"
if [[ -f "${2:-}/FAIL" ]]; then
  echo "finding"
  exit 1
fi
exit 0
SH
chmod +x "$SCAN"

init_repo() {
  local d="$1"
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" config user.email t@t
  git -C "$d" config user.name t
  git -C "$d" -c commit.gpgsign=false commit -q --allow-empty -m init
}

# --- single-repo: feature dir inside a git tree ---
REPO="$WORK/single"
init_repo "$REPO"
FEAT="$REPO/.loop-spec/features/demo"
mkdir -p "$FEAT"
BASE="$(git -C "$REPO" rev-parse HEAD)"
jq -n --arg sha "$BASE" '{schemaVersion:7,slug:"demo",baseSha:$sha,workspace:null}' \
  > "$FEAT/feature.json"

ec=0; out="$(bash "$LIB" "$SCAN" --feature-dir "$FEAT" 2>"$WORK/err")" || ec=$?
check "single-repo exit 0" "0" "$ec"
check "single-repo calls the scan with baseSha and toplevel" \
  "SCAN $BASE $REPO" "$(echo "$out" | head -1)"

jq 'del(.baseSha)' "$FEAT/feature.json" > "$FEAT/feature.json.tmp"
mv "$FEAT/feature.json.tmp" "$FEAT/feature.json"
ec=0; err="$(bash "$LIB" "$SCAN" --feature-dir "$FEAT" 2>&1 >/dev/null)" || ec=$?
check "missing baseSha exits 2" "2" "$ec"
check "missing baseSha names the field" "1" \
  "$(grep -c 'no baseSha' <<<"$err")"

# --- workspace: root is not a git repo; each child is ---
WS="$WORK/ws"
mkdir -p "$WS"
# Deliberately not a git work tree.
if git -C "$WS" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  ws_git=1
else
  ws_git=0
fi
check "workspace root is not a git repo" "0" "$ws_git"

init_repo "$WS/fe"
init_repo "$WS/be"
FE_SHA="$(git -C "$WS/fe" rev-parse HEAD)"
BE_SHA="$(git -C "$WS/be" rev-parse HEAD)"
WS_FEAT="$WS/.loop-spec/features/wsdemo"
mkdir -p "$WS_FEAT"
jq -n --arg root "$WS" --arg fe "$FE_SHA" --arg be "$BE_SHA" \
  '{schemaVersion:7,slug:"wsdemo",baseSha:null,branch:null,baseBranch:null,
    workspace:{root:$root,repos:[
      {name:"fe",path:"fe",branch:"feat/ws",baseSha:$fe,baseBranch:"main"},
      {name:"be",path:"be",branch:"feat/ws",baseSha:$be,baseBranch:"main"}]}}' \
  > "$WS_FEAT/feature.json"

ec=0; out="$(bash "$LIB" "$SCAN" --feature-dir "$WS_FEAT" 2>"$WORK/ws.err")" || ec=$?
check "workspace exit 0" "0" "$ec"
check "workspace scanned fe" "1" "$(grep -c "fe: SCAN $FE_SHA $WS/fe" <<<"$out")"
check "workspace scanned be" "1" "$(grep -c "be: SCAN $BE_SHA $WS/be" <<<"$out")"
check "workspace did not query git at the root" "0" \
  "$(grep -c 'not inside a git' "$WORK/ws.err" || true)"

touch "$WS/be/FAIL"
ec=0; out="$(bash "$LIB" "$SCAN" --feature-dir "$WS_FEAT" 2>/dev/null)" || ec=$?
check "one dirty workspace repo exits 1" "1" "$ec"
check "dirty repo finding is prefixed" "1" "$(grep -c 'be: finding' <<<"$out")"

jq '.workspace.repos = []' "$WS_FEAT/feature.json" > "$WS_FEAT/feature.json.tmp"
mv "$WS_FEAT/feature.json.tmp" "$WS_FEAT/feature.json"
ec=0; err="$(bash "$LIB" "$SCAN" --feature-dir "$WS_FEAT" 2>&1 >/dev/null)" || ec=$?
check "empty workspace.repos exits 2" "2" "$ec"
check "empty repos is named" "1" "$(grep -c 'workspace.repos is empty' <<<"$err")"

ec=0; bash "$LIB" >/dev/null 2>&1 || ec=$?
check "missing args exit 2" "2" "$ec"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
