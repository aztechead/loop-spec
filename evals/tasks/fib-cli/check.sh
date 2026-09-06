#!/usr/bin/env bash
# Acceptance for fib-cli. Prints one `CHECK <name> PASS|FAIL <note>` line per criterion.
cd "$(dirname "$0")"
if [[ -f fib.py ]]; then echo "CHECK fib_py_exists PASS"; else echo "CHECK fib_py_exists FAIL fib.py missing"; fi
out="$(python3 fib.py 10 2>&1 | tail -1)"
if [[ "$out" == "55" ]]; then echo "CHECK fib_10_is_55 PASS"; else echo "CHECK fib_10_is_55 FAIL got '$out'"; fi
out0="$(python3 fib.py 0 2>&1 | tail -1)"
if [[ "$out0" == "0" ]]; then echo "CHECK fib_0_is_0 PASS"; else echo "CHECK fib_0_is_0 FAIL got '$out0'"; fi
if python3 -m unittest discover -s . -p 'test*.py' >/dev/null 2>&1 || python3 -m unittest discover -s tests -p 'test*.py' >/dev/null 2>&1; then
  echo "CHECK unit_tests_pass PASS"; else echo "CHECK unit_tests_pass FAIL"; fi
n="$(ls test*.py tests/test*.py 2>/dev/null | wc -l)"
if (( n > 0 )); then echo "CHECK tests_exist PASS"; else echo "CHECK tests_exist FAIL no test files"; fi
if grep -qi fib README.md 2>/dev/null && ! grep -q Placeholder README.md; then echo "CHECK readme_written PASS"; else echo "CHECK readme_written FAIL"; fi
