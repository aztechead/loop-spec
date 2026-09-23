#!/usr/bin/env python3
"""Compute the cumulative pre-EXECUTE design allowance from route evidence."""
import json
import math
import os
import re
import sys
import time
from datetime import datetime
import feature_read
from loop_log import logger, stdout_log


def epoch(value):
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except (AttributeError, TypeError, ValueError):
        return None


def main(feature_dir, phase):
    try:
        feature = feature_read.load_state(feature_dir)
    except (IOError, ValueError):
        feature = {}
    if not isinstance(feature, dict):
        feature = {}
    classification = feature.get("autonomousClassification") or feature.get("classification") or {}
    if not isinstance(classification, dict):
        classification = {}
    files = classification.get("reviewableEstimatedFiles", classification.get("estimatedFiles"))
    criteria = classification.get("criteriaCount")
    override = os.environ.get("LOOP_SPEC_DESIGN_BUDGET_MINS", "")
    if override and (not override.isascii() or not re.fullmatch(r"[1-9][0-9]*", override)
                     or int(override) > 3600):
        logger.error("design-budget: LOOP_SPEC_DESIGN_BUDGET_MINS must be an integer from 1 to 3600")
        raise SystemExit(2)
    if override:
        budget = int(override)
        reason = "operator-design-budget-override"
    elif (isinstance(files, bool) or not isinstance(files, int) or files < 0 or
            isinstance(criteria, bool) or not isinstance(criteria, int) or criteria < 1):
        budget, reason = 60, "route-size-estimate-unavailable"
    else:
        budget, reason = min(60, 10 + files * 2 + criteria), "route-size-estimate:%d-files-%d-criteria" % (files, criteria)
    elapsed = 0
    seen = set()
    latest_boundary = None
    closed_at = {}
    try:
        with open(feature_dir + "/events.jsonl", encoding="utf-8") as fh:
            for line in fh:
                try:
                    event = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(event, dict):
                    continue
                event_phase = event.get("phase")
                event_name = event.get("event")
                # An execution boundary starts a fresh design allowance.
                # Keep this based on the canonical top-level event fields: data is
                # payload, while phase/event are the ledger schema.
                if event_name in ("phase_start", "phase_end") and event_phase in (
                        "execute", "oneshot", "verify", "iterate"):
                    latest_boundary = event.get("ts") or event.get("timestamp") or latest_boundary
                    elapsed = 0
                    seen.clear()
                    closed_at.clear()
                    continue
                if event_name != "phase_end" or event_phase not in ("spec", "plan"):
                    continue
                data = event.get("data") or {}
                if not isinstance(data, dict):
                    data = {}
                attempt = event.get("attemptId") or data.get("attemptId") or (event.get("phase"), event.get("ts"))
                try:
                    attempt_key = json.dumps(attempt, sort_keys=True)
                except (TypeError, ValueError):
                    attempt_key = repr(attempt)
                if attempt_key in seen:
                    continue
                seconds = event.get("elapsedSeconds", data.get("elapsedSeconds"))
                if (isinstance(seconds, (int, float)) and not isinstance(seconds, bool)
                        and math.isfinite(seconds) and seconds >= 0):
                    elapsed += int(seconds)
                    seen.add(attempt_key)
                    ended = epoch(event.get("ts"))
                    if ended is not None:
                        closed_at[event_phase] = max(closed_at.get(event_phase, 0), ended)
    except OSError:
        # Telemetry is optional; an unreadable ledger must retain the safe size budget.
        pass
    started = epoch(feature.get("currentPhaseStartedAt"))
    boundary_epoch = epoch(latest_boundary)
    if (started is not None and feature.get("currentPhase") == phase
            and closed_at.get(phase, 0) <= started
            # Ledger timestamps have one-second precision; equality means this is
            # the new segment opened at the boundary and must remain chargeable.
            and (boundary_epoch is None or started >= boundary_epoch)):
        elapsed += max(0, int(time.time() - started))
    elapsed_minutes = elapsed // 60
    stdout_log.info("budget=%d elapsed=%d remaining=%d exhausted=%s budgetReason=%s" %
          (budget, elapsed_minutes, max(0, budget - elapsed_minutes),
           str(elapsed_minutes >= budget).lower(), reason))


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[2] not in ("spec", "plan"):
        raise SystemExit("usage: design_budget.py FEATURE_DIR spec|plan")
    main(sys.argv[1], sys.argv[2])
