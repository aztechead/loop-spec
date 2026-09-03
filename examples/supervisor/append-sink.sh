#!/usr/bin/env bash
# append-sink.sh - Event-sink adapter for the reference supervisor: append stdin to a file.
#
# lib/events.sh hands each event line to $LOOP_SPEC_EVENT_SINK on stdin; this one
# appends it to $LOOP_SPEC_EVENT_SINK_FILE. A real supervisor would post it to its
# own stream. Exit non-zero when the file is unset so the emitter's warning names it.
set -euo pipefail
[[ -n "${LOOP_SPEC_EVENT_SINK_FILE:-}" ]] || { echo "append-sink: LOOP_SPEC_EVENT_SINK_FILE is unset" >&2; exit 2; }
cat >> "$LOOP_SPEC_EVENT_SINK_FILE"
