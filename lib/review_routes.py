#!/usr/bin/env python3
"""Validate review routing evidence and group accepted findings by root cause."""
import json
import re

ROUTES = ("intent-gap", "bad-spec", "patch", "defer")
FROZEN = ("Goal", "Goals", "Boundary", "Boundaries (what NOT to do)", "Intent")


def validate(routing):
    if not isinstance(routing, dict) or routing.get("route") not in ROUTES:
        raise ValueError("routing needs route intent-gap|bad-spec|patch|defer")
    route = routing["route"]
    required = {"intent-gap": ("section", "question"),
                "bad-spec": ("section", "replacement"),
                "patch": ("surface", "fixCommit"), "defer": ("reason",)}[route]
    for key in ("cause",) + required:
        if not isinstance(routing.get(key), str) or not routing[key].strip():
            raise ValueError("%s routing needs non-empty %s evidence" % (route, key))
    if route == "intent-gap" and routing["section"] not in FROZEN:
        raise ValueError("intent-gap must name Goal, Boundary, or Intent")
    if route == "bad-spec" and routing["section"] in FROZEN:
        raise ValueError("a frozen intent change is intent-gap, not bad-spec")
    if route == "patch" and (routing["surface"] != "none" or not re.fullmatch(r"[a-f0-9]{7,40}", routing["fixCommit"])):
        raise ValueError("patch requires surface=none and a fixCommit SHA")
    return routing


def findings(text):
    result = []
    in_review = False
    causes = {}
    for number, line in enumerate(text.splitlines(), 1):
        if line.strip().startswith("## "):
            in_review = line.strip() == "## Code review"
        if not in_review or not line.startswith("- ") or not re.search(r"\|\s*verdict:\s*true\b", line):
            continue
        match = re.search(r" \| routing: (\{.*\})\s*$", line)
        if not match:
            raise ValueError("accepted finding at line %d needs routing JSON" % number)
        routing = validate(json.loads(match.group(1)))
        cause = routing["cause"]
        if cause in causes and causes[cause] != routing:
            raise ValueError("findings with root cause %r have conflicting routes" % cause)
        if cause not in causes:
            result.append(dict(routing, finding=line[:match.start()]))
            causes[cause] = routing
    return result
