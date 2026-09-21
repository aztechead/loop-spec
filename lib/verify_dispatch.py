"""Render the verifier assignment from verified phase sources, not lead prose."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

from phase_snapshot import verify


def render(plugin_root, feature_dir, repository_root, feature, instructions, prepared):
    """Return no dispatch when ingress scans or the acceptance policy refuse it."""
    if prepared.get("route") != "continue" or prepared.get("mode", {}).get("acceptance") == "skip":
        return None
    validation = prepared.get("validation") or {}
    if validation.get("ran") and (validation.get("rc") != 0 or validation.get("outcome") != "accepted"):
        raise ValueError("verifier packet requires an accepted repository validation result")
    feature_dir = Path(feature_dir).resolve()
    verify(instructions, plugin_root, feature_dir)
    snapshot = feature_dir / "instruction-snapshots" / Path(instructions["manifest"]).parent.name
    role = (snapshot / "agents/verifier.md").read_text(encoding="utf-8")
    grounding = (snapshot / "skills/shared/verification-grounding.md").read_text(encoding="utf-8")
    template = snapshot / "skills/shared/artifact-templates/VERIFICATION.md.template"
    if not template.is_file():
        raise ValueError("verifier packet template is missing")
    root = Path(repository_root).resolve()
    docs = root / "docs/loop-spec/features" / feature["slug"]
    artifacts = feature.get("artifacts") or {}
    def artifact(key, fallback):
        value = Path(artifacts.get(key) or fallback)
        return str(value if value.is_absolute() else root / value)
    workspace = feature.get("workspace") or {}
    repos = workspace.get("repos") if workspace.get("mode", "single") != "single" else None
    targets = []
    for repo in repos or [{"path": ".", "branch": feature.get("branch"), "baseSha": feature.get("baseSha")}]:
        path = (root / repo["path"]).resolve()
        head = subprocess.check_output(["git", "-C", str(path), "rev-parse", "HEAD"], text=True).strip()
        targets.append({"root": str(path), "branch": repo.get("branch") or feature.get("branch"),
                        "base_sha": repo.get("baseSha"), "candidate_sha": head})
    assignment = {"slug": feature["slug"], "repository_root": str(root), "targets": targets,
                  "branch": feature.get("branch"), "base_sha": feature.get("baseSha"),
                  "spec_path": artifact("spec", docs / "SPEC.md"),
                  "plan_path": artifact("plan", docs / "PLAN.md"),
                  "verification_path": artifact("verification", docs / "VERIFICATION.md"),
                  "template_path": str(template), "validation_json": validation.get("result"),
                  "repository_validation_ran": bool(validation.get("ran"))}
    text = "\n".join([
        "# VERIFY verifier assignment", "",
        "Read this entire packet. Its embedded contracts are authoritative; the coordinator does not summarize them.",
        "Use the named template, including its literal Repository grounding heading. Write only verification_path.",
        "Confirm each checkout HEAD matches candidate_sha before relying on validation_json; otherwise report stale evidence.",
        "Resolve any other plugin-relative contract reference against the frozen snapshot at " + str(snapshot) + ".",
        "If repository validation was skipped by policy, record that fact, never invent an accepted comparison.",
        "", "## Assignment", "```json", json.dumps(assignment, indent=2), "```", "",
        "## Verifier role (frozen source)", role, "",
        "## Verification grounding and validation (frozen source)", grounding,
        "", "Return VERIFIER DONE: <ALL_PASS|FAIL> <Test suite status: PASS|FAIL|N/A> <summary>.", "",
    ])
    dispatch = feature_dir / "dispatch"
    dispatch.mkdir(parents=True, exist_ok=True)
    destination = dispatch / "verify-verifier-brief.md"
    handle, temporary = tempfile.mkstemp(prefix=".verify-verifier-", dir=str(dispatch))
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            stream.write(text)
        os.replace(temporary, destination)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return {"role": "verifier", "model": (feature.get("models") or {}).get("verifier") or "inherit",
            "subagentType": "loop-spec:verifier", "promptFile": str(destination)}
