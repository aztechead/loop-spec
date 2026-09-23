#!/usr/bin/env python3
"""Resolve the session identity shared by launchers, hooks, and the driver."""

import json
import os
import sys
from loop_log import stdout_log


def resolve_session_id(env=None, payload=None):
    """Canonical launcher id, then legacy env, then native tool payload."""
    env = os.environ if env is None else env
    payload = payload or {}
    return (str(env.get("LOOP_SPEC_SESSION_ID") or "").strip()
            or str(env.get("CLAUDE_CODE_SESSION_ID") or "").strip()
            or str(env.get("CLAUDE_SESSION_ID") or "").strip()
            or str(payload.get("session_id") or payload.get("sessionId") or "").strip())


if __name__ == "__main__":
    try:
        payload = json.loads(os.environ.get("LOOP_SPEC_IDENTITY_INPUT") or "{}")
    except ValueError:
        payload = {}
    stdout_log.info(resolve_session_id(payload=payload))
