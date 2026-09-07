#!/usr/bin/env bash
# Tests for hooks/team/secret-guard.sh
# PreToolUse (Write|Edit|MultiEdit|Bash): identities and credential contents stay out of artifacts and context.
set -euo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/secret-guard.sh"
PASS=0
FAIL=0

check() {
  local name="$1" expected="$2" payload="$3"
  shift 3
  local actual=0
  env "$@" bash "$HOOK" >/dev/null 2>&1 <<< "$payload" || actual=$?
  if [[ "$actual" -eq "$expected" ]]; then
    echo "PASS: $name"; ((PASS++)) || true
  else
    echo "FAIL: $name (expected exit $expected, got $actual)"; ((FAIL++)) || true
  fi
}

write() { python3 -c 'import json,sys; print(json.dumps({"tool_name":sys.argv[1],"tool_input":{"file_path":sys.argv[2],"content":sys.argv[3],"new_string":sys.argv[3]}}))' "$1" "$2" "$3"; }
bash_cmd() { python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1"; }

SPEC=/repo/docs/loop-spec/features/demo/SPEC.md
STATE=/repo/.loop-spec/features/demo/spec-interview-transcript.md

# The live shapes: the operator's account email in SPEC.md, the ADC path in the transcript.
check "email in SPEC.md Write denied" 2 "$(write Write "$SPEC" 'Credentials: the chris@example.dev gcloud account is active.')"
check "email in state transcript Edit denied" 2 "$(write Edit "$STATE" 'auth as ops@example.com')"
check "credential path in an artifact denied" 2 "$(write Write "$SPEC" 'ADC at ~/.config/gcloud/application_default_credentials.json')"
check "MultiEdit new_string is scanned" 2 '{"tool_name":"MultiEdit","tool_input":{"file_path":"/repo/docs/loop-spec/features/demo/PLAN.md","edits":[{"old_string":"a","new_string":"owner: me@example.org"}]}}'

# What must still pass: domains, prose about auth, and files outside the artifact dirs.
check "a public domain is not an email" 0 "$(write Write "$SPEC" 'the meldn.dev static site behind Cloud CDN')"
check "auth described without identity passes" 0 "$(write Write "$SPEC" 'An active gcloud account with application-default credentials is present (EVID-003).')"
check "an email in a non-artifact file is not this hook's business" 0 "$(write Write /repo/README.md 'Contact: team@example.com')"

# Credential reads over Bash.
check "cat of the ADC file denied" 2 "$(bash_cmd 'cat ~/.config/gcloud/application_default_credentials.json 2>&1 | python3 -c "import json,sys"')"
check "python open of aws credentials denied" 2 "$(bash_cmd 'python3 - ~/.aws/credentials <<EOF
print(1)
EOF')"
check "head of a private key denied" 2 "$(bash_cmd 'head -3 ~/.ssh/id_ed25519')"
check "jq on a .pem denied" 2 "$(bash_cmd 'jq . /etc/ssl/private/server.pem')"
check "test -f on the ADC file passes" 0 "$(bash_cmd 'test -f ~/.config/gcloud/application_default_credentials.json && echo present')"
check "ls of the ADC file passes" 0 "$(bash_cmd 'ls -la ~/.config/gcloud/application_default_credentials.json')"
check "gcloud auth list passes" 0 "$(bash_cmd 'gcloud auth list 2>&1')"
check "a public key read passes" 0 "$(bash_cmd 'cat ~/.ssh/id_ed25519.pub')"
check "an ordinary cat passes" 0 "$(bash_cmd 'cat root.hcl')"

check "kill switch allows" 0 "$(write Write "$SPEC" 'x@example.com')" LOOP_SPEC_SECRET_GUARD=0
check "malformed payload allowed" 0 'not json'
check "other tools allowed" 0 '{"tool_name":"Read","tool_input":{"file_path":"/x"}}'

echo
echo "secret-guard: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
