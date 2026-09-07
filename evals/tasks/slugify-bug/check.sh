#!/usr/bin/env bash
cd "$(dirname "$0")"
if python3 -m unittest discover -s tests >/dev/null 2>&1; then echo "CHECK tests_pass PASS"; else echo "CHECK tests_pass FAIL"; fi
# The protected-file check is done by the driver from git; here only behavior.
out="$(python3 -c 'from slugify import slugify; print(slugify("  --Hello--  "), slugify("A  B"))' 2>&1)"
if [[ "$out" == "hello a-b" ]]; then echo "CHECK behavior PASS"; else echo "CHECK behavior FAIL got '$out'"; fi
