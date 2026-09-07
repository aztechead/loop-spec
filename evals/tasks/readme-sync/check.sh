#!/usr/bin/env bash
cd "$(dirname "$0")"
ok=1
for flag in --source --dest --exclude --dry-run --verbose; do
  grep -q -- "$flag" README.md || { ok=0; echo "CHECK readme_has_$flag FAIL"; }
done
(( ok )) && echo "CHECK readme_has_all_flags PASS"
if grep -q -- "--compress" README.md; then echo "CHECK stale_flag_removed FAIL"; else echo "CHECK stale_flag_removed PASS"; fi
n="$(ls *.py tests/*.py 2>/dev/null | grep -v '^backup.py$' | wc -l)"
if (( n == 0 )); then echo "CHECK no_code_added PASS"; else echo "CHECK no_code_added FAIL $n extra python files"; fi
