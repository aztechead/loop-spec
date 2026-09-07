#!/usr/bin/env bash
# PreToolUse hook: keep identities and credentials out of cycle artifacts and out of context.
#
# Two live runs (evals/findings-2026-09-07-tf-meldn.md) committed the operator's gcloud
# account email into SPEC.md and EVIDENCE.md and pushed it in the PR, and a lead read
# ~/.config/gcloud/application_default_credentials.json into its context to diagnose an
# auth failure. lib/evidence.sh refuses the email now, but SPEC.md is written with Write,
# and no probe needs the CONTENTS of a credential file: whether it exists is the fact.
# This hook denies the two shapes:
#   Write / Edit / MultiEdit under docs/loop-spec/features/** or .loop-spec/features/**
#     whose new text carries an email address or a credential path.
#   Bash that reads a known credential file (cat, head, tail, less, more, sed, awk, jq,
#     python3 on application_default_credentials.json, ~/.aws/credentials, ~/.netrc,
#     ~/.ssh/id_*, *.pem, *.p12, *.key). `ls`, `test -f`, and `stat` still pass.
# Public domain names (meldn.dev) and mailto-free prose never trip it.
#
# Claude Code contract:
#   exit 0 = allow
#   exit 2 = deny (stderr shown to the model)
#
# Kill switch: LOOP_SPEC_SECRET_GUARD=0 -> exit 0.
# Fail-open: no payload, malformed JSON, no python3 -> exit 0.
set -euo pipefail
if [[ "${LOOP_SPEC_SECRET_GUARD:-1}" == "0" ]]; then
  exit 0
fi
trap 'exit 0' ERR
command -v python3 &>/dev/null || exit 0
INPUT=$(cat 2>/dev/null) || true
[[ -z "$INPUT" ]] && exit 0
VERDICT=$(printf '%s' "$INPUT" | python3 -c '
import json
import re
import sys
try:
    payload = json.load(sys.stdin)
except Exception:
    print("allow")
    raise SystemExit(0)
tool = str(payload.get("tool_name") or "")
inp = payload.get("tool_input") or {}
email = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z][A-Za-z]+")
cred_path = re.compile(r"application_default_credentials|\.aws/credentials|/\.ssh/id_[a-z0-9_]+|\.netrc|\.config/gcloud/(?:credentials|legacy_credentials|access_tokens)")
artifact = re.compile(r"(?:^|/)(?:docs/loop-spec/features|\.loop-spec/features)/")
if tool in ("Write", "Edit", "MultiEdit"):
    path = str(inp.get("file_path") or "")
    if not artifact.search(path):
        print("allow")
        raise SystemExit(0)
    texts = [str(inp.get("content") or ""), str(inp.get("new_string") or "")]
    texts += [str(e.get("new_string") or "") for e in (inp.get("edits") or []) if isinstance(e, dict)]
    body = "\n".join(texts)
    m = email.search(body)
    if m:
        print("email\t" + m.group(0))
    elif cred_path.search(body):
        print("credpath\t" + cred_path.search(body).group(0))
    else:
        print("allow")
    raise SystemExit(0)
if tool == "Bash":
    cmd = str(inp.get("command") or "")
    reader = re.compile(r"\b(?:cat|head|tail|less|more|sed|awk|jq|python3?|base64|xxd|strings|cp|scp|curl)\b[^|;&\n]*(application_default_credentials\.json|/\.aws/credentials|/\.netrc|/\.ssh/id_[a-z0-9_]+\b(?!\.pub)|\S+\.(?:pem|p12|pfx)\b|\S+/[^/\s]*\.key\b)")
    m = reader.search(cmd)
    if m:
        print("credread\t" + m.group(1))
    else:
        print("allow")
    raise SystemExit(0)
print("allow")
')

kind="${VERDICT%%$'\t'*}"; hit="${VERDICT#*$'\t'}"
case "$kind" in
  email)
    echo "DENY: a cycle artifact must not carry an email address ($hit). Cite that auth exists (\"an active gcloud account\"), never the identity; the PR publishes this file. (Disable: LOOP_SPEC_SECRET_GUARD=0)" >&2
    exit 2 ;;
  credpath)
    echo "DENY: a cycle artifact must not name a credential file ($hit). Record the tool and that it is authenticated, not where its secret lives. (Disable: LOOP_SPEC_SECRET_GUARD=0)" >&2
    exit 2 ;;
  credread)
    echo "DENY: this command reads a credential file ($hit) into the transcript. No cycle step needs its contents; \`test -f\` or \`ls\` proves it exists, and the tool's own auth command (gcloud auth list, aws sts get-caller-identity) proves it works. (Disable: LOOP_SPEC_SECRET_GUARD=0)" >&2
    exit 2 ;;
  *) exit 0 ;;
esac
