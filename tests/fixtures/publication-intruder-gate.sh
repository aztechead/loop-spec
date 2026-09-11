#!/usr/bin/env bash
# Fixture for tests/lib/phase-exit.test.sh (publication contract, AC2): a graph gate
# body that proves whether it ran (MARKER_FILE) and simulates a write that races the
# parent's ingress token (INTRUDE_FEATURE_DIR/INTRUDE_LIB), exactly as an unrelated
# process outside the parent's token flow would -- LOOP_SPEC_PUBLICATION_TOKEN is
# unset before the plain write so it never carries the parent's token forward. Once a
# feature carries artifactPublication (task-009 strict enforcement), even this
# unrelated process must begin its own operation rather than bypass the token
# entirely, so it captures its own fresh ingress first.
set -euo pipefail
: "${MARKER_FILE:?}" "${INTRUDE_FEATURE_DIR:?}" "${INTRUDE_LIB:?}"
touch "$MARKER_FILE"
unset LOOP_SPEC_PUBLICATION_TOKEN LOOP_SPEC_PUBLICATION_TOKEN_OUTPUT
INTRUDE_TOKEN="$(mktemp "${TMPDIR:-/tmp}/publication-intruder-token.XXXXXX")"
python3 "$(dirname "$INTRUDE_LIB")/feature_write.py" ingress "$INTRUDE_FEATURE_DIR" > "$INTRUDE_TOKEN"
bash "$INTRUDE_LIB" set "$INTRUDE_FEATURE_DIR" warnings '["intruder"]' --token "$INTRUDE_TOKEN" >/dev/null
rm -f "$INTRUDE_TOKEN"
