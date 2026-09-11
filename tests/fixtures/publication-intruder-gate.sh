#!/usr/bin/env bash
# Fixture for tests/lib/phase-exit.test.sh (publication contract, AC2): a graph gate
# body that proves whether it ran (MARKER_FILE) and simulates a write that races the
# parent's ingress token (INTRUDE_FEATURE_DIR/INTRUDE_LIB), exactly as an unrelated
# process outside the parent's token flow would -- LOOP_SPEC_PUBLICATION_TOKEN is
# unset before the plain write so it never carries the parent's token forward.
set -euo pipefail
: "${MARKER_FILE:?}" "${INTRUDE_FEATURE_DIR:?}" "${INTRUDE_LIB:?}"
touch "$MARKER_FILE"
unset LOOP_SPEC_PUBLICATION_TOKEN LOOP_SPEC_PUBLICATION_TOKEN_OUTPUT
bash "$INTRUDE_LIB" set "$INTRUDE_FEATURE_DIR" warnings '["intruder"]' >/dev/null
