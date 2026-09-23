"""Notice a lead repeating driver calls that change nothing, and name the one command
that moves the cycle on.

The 6.9.1 upstream run alternated `next` and `phase-begin verify` eight times in 25
minutes; the REDO counter saw none of it because it counts only `--returned-from`.
The match key is the state the calls could have changed (every repo's HEAD and
worktree, the phase-shaped feature.json fields, the error), never the command, so
alternating commands still count. Guidance only: it never refuses or escalates.
"""
import hashlib
import json
import os
import subprocess

THRESHOLD = 3
SIDECAR = "driver-stuck.json"


def fingerprint(feat, roots, error):
    """None when a root cannot be read: no fingerprint, no note."""
    parts = []
    for root in roots:
        for args in (["rev-parse", "HEAD"], ["status", "--porcelain", "--untracked-files=all"]):
            out = subprocess.run(["git", "-C", root] + args, stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL, universal_newlines=True)
            if out.returncode:
                return None
            parts.append(out.stdout)
    gate = feat.get("currentGate") or {}
    # driverNext carries timestamps and driverRedo counts every REDO; either would make
    # each call look like progress.
    parts.append(json.dumps([feat.get("currentPhase"), (feat.get("driverNext") or {}).get("phase"),
                             len(feat.get("pendingRemediationTasks") or []), len(feat.get("gateHistory") or []),
                             gate.get("gate"), gate.get("round"), feat.get("completedPhases"), error]))
    return hashlib.sha256("\0".join(parts).encode("utf-8")).hexdigest()


def hint(feat, feature_dir, command, drv, paused_node, error):
    """The first rule that matches the state names the next command."""
    run = "bash %s" % drv
    if paused_node:
        return ("the cycle is paused at %s for a human answer; end this session and resume "
                "through a fresh /loop-spec:cycle invocation" % paused_node)
    if error:
        return "the call failed the same way each time; fix what the error names before calling again"
    phase = (feat.get("driverNext") or {}).get("phase") or feat.get("currentPhase") or ""
    verify_gates = [g for g in feat.get("gateHistory") or [] if isinstance(g, dict) and g.get("phase") == "verify"]
    if phase == "verify" and feat.get("pendingRemediationTasks") and verify_gates \
            and verify_gates[-1].get("result") == "fail":
        return ("the queued remediation task goes to EXECUTE: %s next --feature-dir %s --returned-from verify"
                % (run, feature_dir))
    gate = (feat.get("currentGate") or {}).get("gate")
    if gate:
        return ("the critique gate %s is open: %s critique resume --feature-dir %s, dispatch the challenger "
                "on its promptFile, and pass the reply to the step it names" % (gate, run, feature_dir))
    if (feat.get("driverRedo") or {}).get("phase") == phase:
        return ("the last REDO's FLAG lines still stand; fix them in the artifact, then %s next "
                "--feature-dir %s --returned-from %s" % (run, feature_dir, phase))
    if command == "phase-begin":
        return ("phase-begin %s already answered; act on that answer (dispatch the agent its packet names), "
                "then %s next --feature-dir %s --returned-from %s" % (phase, run, feature_dir, phase))
    return ("%s phase-begin %s --feature-dir %s once, act on its packet, then %s next --feature-dir %s "
            "--returned-from %s" % (run, phase, feature_dir, run, feature_dir, phase))


def observe(feature_dir, feat, roots, command, drv, paused_node=None, error=None):
    """Count this call against the last one; return the NOTE line at THRESHOLD or past it."""
    key = fingerprint(feat, roots, error)
    if key is None:
        return None
    path = os.path.join(feature_dir, SIDECAR)
    try:
        with open(path, encoding="utf-8") as fh:
            prior = json.load(fh)
    except (OSError, ValueError):
        # First call, or a sidecar cut short mid-write: the count starts over, which can
        # only delay a note, never invent one.
        prior = {}
    count = int(prior.get("count") or 0) + 1 if prior.get("key") == key else 1
    with open(path, "w", encoding="utf-8") as fh:
        json.dump({"key": key, "count": count}, fh)
    if count < THRESHOLD:
        return None
    return ("NOTE [stuck] %d driver calls in a row changed nothing (HEAD, worktree, feature state). "
            "Next: %s" % (count, hint(feat, feature_dir, command, drv, paused_node, error)))
