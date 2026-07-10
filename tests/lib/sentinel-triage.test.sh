#!/usr/bin/env bash
# Tests for lib/sentinel-triage.sh (deterministic sentinel triage, ROADMAP-3.0 A2).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/lib/sentinel-triage.sh"
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

WORK="${TMPDIR:-/tmp}/sentinel-triage-test.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"
QUEUE="$WORK/sentinel-queue.json"
CONF="$WORK/sentinel.conf"

# Pin the clock: NOW = 2026-07-09T00:00:00Z
NOW=1783728000
iso() { # iso <days-ago>
  python3 -c "from datetime import datetime,timezone,timedelta; print((datetime.fromtimestamp($NOW, tz=timezone.utc)-timedelta(days=$1)).strftime('%Y-%m-%dT%H:%M:%SZ'))"
}

item() { # item <source> <id> <kind> <days-ago-or-null> [title]
  local up="null"
  [[ "$4" != "null" ]] && up="\"$(iso "$4")\""
  jq -cn --arg s "$1" --arg i "$2" --arg k "$3" --arg t "${5:-item $2}" --argjson u "$up" \
    '{source: $s, id: $i, title: $t, body: "b", url: null, kind: $k, updatedAt: $u}'
}

# ── sources: defaults all enabled ─────────────────────────────────────────────
out="$(bash "$SCRIPT" sources --conf "$WORK/no-conf")"
check "sources: all four by default" "gh-issues ci-failures backlog assessment" "$(tr '\n' ' ' <<<"$out" | sed 's/ $//')"
printf 'ENABLE_CI_FAILURES=0\nENABLE_ASSESSMENT=0\n' > "$CONF"
out="$(bash "$SCRIPT" sources --conf "$CONF")"
check "sources: conf disables" "gh-issues backlog" "$(tr '\n' ' ' <<<"$out" | sed 's/ $//')"
rm -f "$CONF"

# ── run: scoring order is source-weight x kind x recency ─────────────────────
# ci bug fresh:   8*3*3 = 72 ; gh bug fresh: 5*3*3 = 45 ; gh gap old: 5*2*1 = 10
# backlog chore old: 3*1*1 = 3
jq -cs . > "$WORK/in.json" << EOF
$(item backlog bl-1 chore 20)
$(item gh-issues gh-2 gap 20)
$(item gh-issues gh-1 bug 1)
$(item ci-failures ci-1 bug 1)
EOF
out="$(bash "$SCRIPT" run --in "$WORK/in.json" --out "$QUEUE" --conf "$WORK/no-conf" --now "$NOW")"
check "run: queue ordered by score" "ci-1 gh-1 gh-2 bl-1" "$(jq -r '.queue | map(.id) | join(" ")' <<<"$out")"
check "run: scores deterministic" "72 45 10 3" "$(jq -r '.queue | map(.score | tostring) | join(" ")' <<<"$out")"
check "run: schema version" "1" "$(jq '.schema' <<<"$out")"
check "run: queue file written" "1" "$([[ -f "$QUEUE" ]] && echo 1 || echo 0)"
check "run: needsHuman empty" "0" "$(jq '.needsHuman | length' <<<"$out")"

# same input, same output (determinism pin)
out2="$(bash "$SCRIPT" run --in "$WORK/in.json" --out "$QUEUE" --conf "$WORK/no-conf" --now "$NOW")"
check "run: same input same queue" "$(jq -c '.queue' <<<"$out")" "$(jq -c '.queue' <<<"$out2")"

# ── recency buckets ───────────────────────────────────────────────────────────
jq -cs . > "$WORK/rec.json" << EOF
$(item gh-issues gh-old bug 10)
$(item gh-issues gh-week bug 5)
$(item gh-issues gh-fresh bug 1)
$(item gh-issues gh-undated bug null)
EOF
out="$(bash "$SCRIPT" run --in "$WORK/rec.json" --out "$QUEUE" --conf "$WORK/no-conf" --now "$NOW")"
check "recency: fresh=3x week=2x old/undated=1x" "45 30 15 15" "$(jq -r '.queue | map(.score | tostring) | join(" ")' <<<"$out")"
# tie between old and undated: undated has no date (epoch 0) -> sorts after; id tiebreak not needed
check "recency: dated beats undated on tie" "gh-old gh-undated" "$(jq -r '.queue[2:] | map(.id) | join(" ")' <<<"$out")"

# ── needs-human routing (never silently dropped, never silently run) ──────────
jq -cs . > "$WORK/nh.json" << EOF
$(item gh-issues gh-ok bug 1)
$(item gh-issues gh-weird unknown 1)
$(item jira jira-1 bug 1)
{"source": "gh-issues", "id": "", "title": "no id", "body": "b", "url": null, "kind": "bug", "updatedAt": null}
EOF
out="$(bash "$SCRIPT" run --in "$WORK/nh.json" --out "$QUEUE" --conf "$WORK/no-conf" --now "$NOW")"
check "needs-human: only clean item queued" "gh-ok" "$(jq -r '.queue | map(.id) | join(" ")' <<<"$out")"
check "needs-human: three routed" "3" "$(jq '.needsHuman | length' <<<"$out")"
check "needs-human: unknown kind reason" "unclassifiable-kind" "$(jq -r '.needsHuman[] | select(.id=="gh-weird") | .reason' <<<"$out")"
check "needs-human: unknown source reason" "unknown-source" "$(jq -r '.needsHuman[] | select(.id=="jira-1") | .reason' <<<"$out")"
check "needs-human: missing id reason" "missing-id-or-title" "$(jq -r '.needsHuman[] | select(.title=="no id") | .reason' <<<"$out")"

# ── conf: weights, enable flags, queue depth ──────────────────────────────────
printf 'WEIGHT_BACKLOG=100\nENABLE_GH_ISSUES=0\nMAX_QUEUE_DEPTH=1\n' > "$CONF"
jq -cs . > "$WORK/conf-in.json" << EOF
$(item gh-issues gh-1 bug 1)
$(item backlog bl-1 chore 1)
$(item ci-failures ci-1 bug 20)
EOF
out="$(bash "$SCRIPT" run --in "$WORK/conf-in.json" --out "$QUEUE" --conf "$CONF" --now "$NOW")"
# backlog chore fresh: 100*1*3=300 beats ci bug old: 8*3*1=24; gh disabled; depth truncates to 1
check "conf: custom weight wins" "bl-1" "$(jq -r '.queue[0].id' <<<"$out")"
check "conf: depth truncates" "1" "$(jq '.queue | length' <<<"$out")"
check "conf: disabled source dropped (not needs-human)" "0" "$(jq '[.needsHuman[] | select(.source=="gh-issues")] | length' <<<"$out")"

# ── show ──────────────────────────────────────────────────────────────────────
out="$(bash "$SCRIPT" show --out "$QUEUE")"
check "show: prints queue file" "1" "$(jq '.schema' <<<"$out")"
ec=0; bash "$SCRIPT" show --out "$WORK/absent.json" >/dev/null 2>&1 || ec=$?
check "show: no queue file exits 1" "1" "$ec"

# ── bad invocations ───────────────────────────────────────────────────────────
ec=0; echo 'not json' | bash "$SCRIPT" run --out "$QUEUE" --conf "$WORK/no-conf" >/dev/null 2>&1 || ec=$?
check "run: garbage stdin exits 2" "2" "$ec"
ec=0; echo '{"an":"object"}' | bash "$SCRIPT" run --out "$QUEUE" --conf "$WORK/no-conf" >/dev/null 2>&1 || ec=$?
check "run: non-array input exits 2" "2" "$ec"
ec=0; bash "$SCRIPT" bogus >/dev/null 2>&1 || ec=$?
check "unknown subcommand exits 2" "2" "$ec"
ec=0; bash "$SCRIPT" run --in "$WORK/in.json" --out "$QUEUE" --now "not-a-number" >/dev/null 2>&1 || ec=$?
check "run: bad --now exits 2" "2" "$ec"

# empty input is fine: empty queue, not an error
out="$(echo '[]' | bash "$SCRIPT" run --out "$QUEUE" --conf "$WORK/no-conf" --now "$NOW")"
check "run: empty input empty queue" "0" "$(jq '.queue | length' <<<"$out")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
