#!/usr/bin/env python3
"""Validate a graph node's declared feature-state reads."""

import json
import sys

RELOCATED = ("branch", "baseSha", "baseBranch")


def unsatisfied_reads(feature, reads):
    """Return required reads absent from a projected feature state.

    Workspace mode stores branch identity in every workspace repo. The projection
    is supplied by the caller so CLI and in-process callers share feature_read's
    typed/drop-strays behavior.
    """
    if not isinstance(feature, dict):
        raise ValueError("feature state must be a JSON object")
    if not isinstance(reads, list) or any(not isinstance(key, str) for key in reads):
        raise ValueError("node reads must be a JSON array of strings")
    workspace = feature.get("workspace")
    repos = workspace.get("repos") if isinstance(workspace, dict) else None
    if not isinstance(repos, list):
        repos = None

    def repo_has(repo, key):
        return isinstance(repo, dict) and isinstance(repo.get(key), str) and repo[key].strip() != ""

    def satisfied(key):
        if key in feature and feature[key] is not None:
            return True
        return (repos is not None and key in RELOCATED and len(repos) > 0
                and all(repo_has(repo, key) for repo in repos))

    return [key for key in reads if not satisfied(key)]


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: state_reads.py FEATURE_JSON READS_JSON")
    try:
        missing = unsatisfied_reads(json.loads(sys.argv[1]), json.loads(sys.argv[2]))
    except (TypeError, ValueError, json.JSONDecodeError) as exc:
        print("state_reads.py: %s" % exc, file=sys.stderr)
        raise SystemExit(1)
    print("\n".join(missing))
