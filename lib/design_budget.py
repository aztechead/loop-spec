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
        print("design-budget: LOOP_SPEC_DESIGN_BUDGET_MINS must be an integer from 1 to 3600", file=sys.stderr)
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
    closed_at = {}
    try:
        with open(feature_dir + "/events.jsonl", encoding="utf-8") as fh:
            for line in fh:
                try:
                    event = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(event, dict) or event.get("event") != "phase_end" or event.get("phase") not in ("spec", "discuss", "plan"):
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
                        closed_at[event.get("phase")] = max(closed_at.get(event.get("phase"), 0), ended)
    except OSError:
        # Telemetry is optional; an unreadable ledger must retain the safe size budget.
        pass
    started = epoch(feature.get("currentPhaseStartedAt"))
    if (started is not None and feature.get("currentPhase") == phase
            and closed_at.get(phase, 0) <= started):
        elapsed += max(0, int(time.time() - started))
    elapsed_minutes = elapsed // 60
    print("budget=%d elapsed=%d remaining=%d exhausted=%s budgetReason=%s" %
          (budget, elapsed_minutes, max(0, budget - elapsed_minutes),
           str(elapsed_minutes >= budget).lower(), reason))


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[2] not in ("spec", "discuss", "plan"):
        raise SystemExit("usage: design_budget.py FEATURE_DIR spec|discuss|plan")
    main(sys.argv[1], sys.argv[2])
