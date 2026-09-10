#!/usr/bin/env bash
# feature.json has one reader: lib/feature_read.py (launched by lib/feature-read.sh),
# whose key space is graph/schema.json's stateKey enum. Every other `jq ... feature.json`
# was its own untyped reader (the port plan, WP3). This pin
# fails on a feature.json read anywhere under lib/, hooks/, or the skills' prose outside
# the two state modules, so a new reader cannot come back once a script is migrated.
#
# Two passes per file, because the first version of this pin needed the reader and the
# path on one line and five scripts slipped past it by binding the path to a variable
# first (port audit 1, F7): pass one collects every variable bound to a
# path ending in feature.json; pass two flags any code line that hands the literal or
# one of those variables to jq, python3, cat, awk, sed, grep, a redirect, or a file open.
#
# The allow-list below is a ratchet, not a permit: each entry names a read that is not a
# key read and says why. It may only shrink.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PASS=0; FAIL=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then echo "PASS: $name"; PASS=$((PASS+1))
  else echo "FAIL: $name (expected '$expected', got '$actual')"; FAIL=$((FAIL+1)); fi
}

# file:line of reads that are not key reads. A content hash of the document is the
# document, not a key, and the typed reader cannot answer it.
ALLOWED=$(cat <<'LIST'
lib/graph/checkpoint.sh	cksum	the ledger records a hash of the whole document
lib/graph/port-local.sh	cksum	the port compares a hash of the whole document
lib/state-ref.sh	cat	git cat-file reads the snapshot blob on the ref, the store owned by the state module
lib/graph/handoff.sh	cksum	the handoff id hashes the whole document
LIST
)

offenders=$(LOOP_SPEC_ALLOWED="$ALLOWED" python3 - <<'PY'
import os, re, sys
allowed = set()
for line in os.environ.get("LOOP_SPEC_ALLOWED", "").splitlines():
    if line.strip():
        path, tool = line.split("\t")[:2]
        allowed.add((path, tool))
files = []
for base in ("lib", "hooks", "skills"):
    for d, _, names in os.walk(base):
        for n in names:
            p = os.path.join(d, n)
            if p.endswith(".test.sh") or p in ("lib/feature_read.py", "lib/feature_write.py"):
                continue
            if p.endswith((".sh", ".py")) or (base == "skills" and p.endswith(".md")):
                files.append(p)
BIND = re.compile(r'^\s*(?:local\s+|export\s+)?([A-Za-z_][A-Za-z0-9_]*)=\s*"?[^;#]*feature\.json"?\s*$')
BIND_PY = re.compile(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*.*feature\.json')
TOOLS = re.compile(r'\b(jq|python3|cat(?=\s)|awk|sed|grep|open|json\.load|read_text|read_bytes|cksum)\b|(?<!<)<(?!<)')
TOOLS_PROSE = re.compile(r'\b(jq|python3|cat(?=\s)|awk|sed|grep)\b')
NOT_A_READ = re.compile(r'^\s*(?:#|\[\[|\[ |if \[\[|if \[ |echo |printf |find |cp |mv |touch |rm |ls |test |\|\| |&& \[\[)')
out = []
for p in sorted(files):
    lines = open(p, encoding="utf-8", errors="replace").read().split("\n")
    names = set()
    for line in lines:
        m = BIND.match(line) or BIND_PY.match(line)
        if m and "feature.json" in line:
            names.add(m.group(1))
    refs = [re.compile(r'\$\{?' + re.escape(n) + r'\b') for n in names]
    for i, line in enumerate(lines, 1):
        code = line.split("#", 1)[0] if not p.endswith(".md") else line
        if "feature.json" not in code and not any(r.search(code) for r in refs):
            continue
        if NOT_A_READ.match(code) or BIND.match(code) or BIND_PY.match(code):
            continue
        m = (TOOLS_PROSE if p.endswith(".md") else TOOLS).search(code)
        if not m:
            continue
        tool = m.group(1) or "<"
        if "feature-read.sh" in code or "feature_read" in code or "feature-write.sh" in code:
            continue
        if (p, tool) in allowed:
            continue
        out.append("%s:%d\t%s\t%s" % (p, i, tool, code.strip()[:90]))
print("\n".join(out))
PY
)
check "no feature.json read outside the state modules and the allow-list" "" "$offenders"
# The allow-list is a ratchet: every entry must still name a read the scan sees.
for entry in $(printf '%s\n' "$ALLOWED" | cut -f1 | sed '/^$/d'); do
  check "allow-list entry still reads feature.json: $entry" "1" "$(grep -cE 'cksum <"\$fj"|cksum <"\$feature_dir/feature\.json"|cat-file -p .*feature\.json' "$entry" | awk '{print ($1 > 0)}')"
done
check "lib/feature_read.py reads the key space from graph/schema.json" "1" "$(grep -c 'graph", "schema.json"' lib/feature_read.py)"
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
