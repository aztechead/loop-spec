#!/usr/bin/env bash
cd "$(dirname "$0")"
if python3 -m unittest discover -s tests >/dev/null 2>&1; then echo "CHECK tests_pass PASS"; else echo "CHECK tests_pass FAIL"; fi
f="$(mktemp -u).json"
python3 -m todo.cli --file "$f" add "late" --due 2030-01-05 >/dev/null 2>&1 || python3 -m todo.cli --file "$f" add --due 2030-01-05 "late" >/dev/null 2>&1
python3 -m todo.cli --file "$f" add "none" >/dev/null 2>&1
python3 -m todo.cli --file "$f" add "early" --due 2029-06-01 >/dev/null 2>&1 || python3 -m todo.cli --file "$f" add --due 2029-06-01 "early" >/dev/null 2>&1
out="$(python3 -m todo.cli --file "$f" list --sort due 2>&1)"
first="$(echo "$out" | sed -n 1p)"; last="$(echo "$out" | sed -n 3p)"
if [[ "$first" == *early* && "$last" == *none* ]]; then echo "CHECK sort_due_order PASS"; else echo "CHECK sort_due_order FAIL: $(echo "$out" | tr '\n' '|')"; fi
if [[ "$out" == *2029-06-01* ]]; then echo "CHECK due_shown PASS"; else echo "CHECK due_shown FAIL"; fi
python3 -m todo.cli --file "$f" add "bad" --due 2030-13-99 >/dev/null 2>&1; rc=$?
if [[ $rc -eq 2 ]]; then echo "CHECK bad_date_exit_2 PASS"; else echo "CHECK bad_date_exit_2 FAIL rc=$rc"; fi
if grep -rqi "due" tests/ 2>/dev/null; then echo "CHECK due_tests_added PASS"; else echo "CHECK due_tests_added FAIL"; fi
rm -f "$f"
