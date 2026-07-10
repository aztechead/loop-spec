#!/usr/bin/env bash
# Tests for lib/sentinel-run.sh (sentinel drive-loop mechanics, ROADMAP-3.0 A3+A4).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/lib/sentinel-run.sh"
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

WORK="${TMPDIR:-/tmp}/sentinel-run-test.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"

QUEUE="$WORK/queue.json"
EVENTS="$WORK/events.jsonl"
CONF="$WORK/no-conf"
# Base the pinned clock on NOW-ish wall time: `next` pins eligibility with
# --now, but the pick events it writes carry real wall-clock timestamps, so a
# pinned clock in the past would see every pick as "in the future = cooling".
NOW="$(date -u +%s)"

mk_queue() { # mk_queue <queue-items-json-array>
  jq -n --argjson q "$1" \
    '{schema:1, generatedAt:"2026-07-10T00:00:00Z", queue:$q, needsHuman:[]}' > "$QUEUE"
}

TWO_ITEMS='[
  {"source":"ci-failures","id":"ci-tests","title":"CI failure","body":"b","url":"u","kind":"bug","updatedAt":"2026-07-09T00:00:00Z","score":24},
  {"source":"backlog","id":"backlog-x","title":"a gap","body":"b","url":null,"kind":"gap","updatedAt":"2026-07-09T00:00:00Z","score":6}]'

# ── next: head of the queue, pick recorded ────────────────────────────────────
mk_queue "$TWO_ITEMS"
out="$(bash "$SCRIPT" next --queue "$QUEUE" --events "$EVENTS" --conf "$CONF" --now "$NOW")"
check "next: returns the head" "ci-tests" "$(jq -r '.id' <<<"$out")"
check "next: pick recorded" "1" "$(jq -s '[.[] | select(.event == "picked" and .id == "ci-tests")] | length' "$EVENTS")"

# ── next: a recent pick cools the item down; the next item surfaces ───────────
out="$(bash "$SCRIPT" next --queue "$QUEUE" --events "$EVENTS" --conf "$CONF" --now "$NOW")"
check "next: cooled-down head skipped" "backlog-x" "$(jq -r '.id' <<<"$out")"
ec=0; bash "$SCRIPT" next --queue "$QUEUE" --events "$EVENTS" --conf "$CONF" --now "$NOW" >/dev/null 2>"$WORK/err" || ec=$?
check "next: all cooling -> exit 1" "1" "$ec"
check "next: all cooling reason named" "1" "$(grep -c 'all-cooling-down' "$WORK/err")"

# ── next: cooldown expires (default 24h) ──────────────────────────────────────
LATER=$(( NOW + 25 * 3600 ))
out="$(bash "$SCRIPT" next --queue "$QUEUE" --events "$EVENTS" --conf "$CONF" --now "$LATER")"
check "next: pick eligible again after cooldown" "ci-tests" "$(jq -r '.id' <<<"$out")"

# ── next: conf overrides the cooldown ─────────────────────────────────────────
rm -f "$EVENTS"
printf 'PICK_COOLDOWN_HOURS=1\n' > "$WORK/short.conf"
bash "$SCRIPT" next --queue "$QUEUE" --events "$EVENTS" --conf "$WORK/short.conf" --now "$NOW" >/dev/null
out="$(bash "$SCRIPT" next --queue "$QUEUE" --events "$EVENTS" --conf "$WORK/short.conf" --now "$(( NOW + 2 * 3600 ))")"
check "next: short conf cooldown expires sooner" "ci-tests" "$(jq -r '.id' <<<"$out")"

# ── next --peek: answers without recording ────────────────────────────────────
rm -f "$EVENTS"
out="$(bash "$SCRIPT" next --queue "$QUEUE" --events "$EVENTS" --conf "$CONF" --now "$NOW" --peek)"
check "peek: returns the head" "ci-tests" "$(jq -r '.id' <<<"$out")"
check "peek: nothing recorded" "0" "$([[ -f "$EVENTS" ]] && echo 1 || echo 0)"

# ── next: empty / missing queue ───────────────────────────────────────────────
mk_queue '[]'
ec=0; bash "$SCRIPT" next --queue "$QUEUE" --events "$EVENTS" --conf "$CONF" >/dev/null 2>"$WORK/err" || ec=$?
check "next: empty queue exit 1" "1" "$ec"
check "next: empty queue reason named" "1" "$(grep -c 'queue-empty' "$WORK/err")"
ec=0; bash "$SCRIPT" next --queue "$WORK/absent.json" >/dev/null 2>"$WORK/err" || ec=$?
check "next: missing queue file exit 1" "1" "$ec"
check "next: missing queue reason named" "1" "$(grep -c 'no-queue-file' "$WORK/err")"
echo 'not json' > "$QUEUE"
ec=0; bash "$SCRIPT" next --queue "$QUEUE" >/dev/null 2>&1 || ec=$?
check "next: corrupt queue exit 2" "2" "$ec"

# ── record: appends decisions, warn-only ──────────────────────────────────────
rm -f "$EVENTS"
bash "$SCRIPT" record skipped --id gh-9 --source gh-issues --reason "duplicate" --events "$EVENTS"
row="$(tail -1 "$EVENTS")"
check "record: event" "skipped" "$(jq -r '.event' <<<"$row")"
check "record: id" "gh-9" "$(jq -r '.id' <<<"$row")"
check "record: reason" "duplicate" "$(jq -r '.reason' <<<"$row")"
check "record: ts present" "string" "$(jq -r '.ts | type' <<<"$row")"
ec=0; bash "$SCRIPT" record skipped --events "$EVENTS" >/dev/null 2>&1 || ec=$?
check "record: missing --id warns but exits 0" "0" "$ec"
check "record: missing --id writes nothing" "1" "$(wc -l < "$EVENTS" | tr -d ' ')"

# ── bad invocations ───────────────────────────────────────────────────────────
ec=0; bash "$SCRIPT" pop >/dev/null 2>&1 || ec=$?
check "unknown subcommand exits 2" "2" "$ec"
ec=0; bash "$SCRIPT" next --now "not-a-number" >/dev/null 2>&1 || ec=$?
check "bad --now exits 2" "2" "$ec"
ec=0; bash "$SCRIPT" record >/dev/null 2>&1 || ec=$?
check "record without event exits 2" "2" "$ec"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
