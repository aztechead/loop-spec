#!/usr/bin/env python3
# Artifact publication: shared lock order, ingress CAS, and durable rollback records.
"""Consumers retain capture's token across work, stage below publication-staging,
and publish {version:1,files:[{source,target}],updates:[{path,value}]}.
Targets are registered artifact keys; stage(directory, name, bytes) returns a
manifest source. CLI targets are spec/plan/patterns/verification/tasks, using the
feature's pointers or canonical defaults. CLI updates permit warnings only.
Trusted controllers pass registry and allowed_updates to publish_locked; capture
must receive the same registry. Absolute existing pointers are accepted only inside those same roots. Registry
paths stay inside the feature state or
its docs/loop-spec/features/<slug> tree. Controllers grant phase updates only
after their gates. On relocation a controller supplies registry={"tasks":"tasks.json"}
to capture/publish/recover when persisted absolute pointers name the old checkout;
journal targets are logical keys, so recovery never follows the old absolute path.
The controller retains that resolver until it updates its persisted pointer.
Locks must be held when calling *_locked functions. Publish returns
an explicit refreshed token for the caller's own next write. Recover rolls back
an unfinished transaction before new work; generation never decreases.
"""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import uuid

from feature_write import parse_json, persist, prepare_state, publish, write_state_locked, state_snapshot, sync_directory, read_bounded
from feature_read import load_state


def safe_path(root, relative):
  if root.is_symlink():
    raise ValueError("symlink is not a publication root: {}".format(root))
  path = Path(relative)
  if path.is_absolute() or not path.parts or any(p in ("..", ".") for p in path.parts):
    raise ValueError("unsafe relative path: {}".format(relative))
  result = root
  for part in path.parts:
    result = result / part
    if result.is_symlink():
      raise ValueError("symlink is not a publication path: {}".format(result))
  return result


@contextmanager
def locked_feature(directory):
  if directory.is_symlink() or not directory.is_dir():
    raise ValueError("feature directory must be a real directory")
  locks = []
  try:
    for name in (".artifact-publication.lock", ".feature-write.lock"):
      path = safe_path(directory, name)
      lock = path.open("a")
      locks.append(lock)
      fcntl.flock(lock, fcntl.LOCK_EX)
    safe_path(directory, "feature.json")
    yield
  finally:
    for lock in reversed(locks):
      lock.close()


def digest(path):
  if not path.exists():
    return None
  if not path.is_file():
    raise ValueError("input is not a file: {}".format(path))
  result = hashlib.sha256()
  with path.open("rb") as stream:
    for chunk in iter(lambda: stream.read(65536), b""):
      result.update(chunk)
  return result.hexdigest()


def refuse_pending(directory):
  path = safe_path(directory, "feature.json")
  if path.exists() and load_state(directory).get("artifactPublication", {}).get("migration") is not None:
    raise ValueError("active migration refuses ordinary publication")
  journal = safe_path(directory, "publication-generations/active.json")
  if journal.exists():
    raise ValueError("unfinished publication; run artifact-publication.sh recover")


def artifact_paths(directory, state, registry=None):
  paths = {}
  root = next((p for p in directory.parents if (p / ".git").exists()), None)
  if directory.parent.name == "features" and directory.parent.parent.name == ".loop-spec":
    root = directory.parent.parent.parent
  slug = state.get("slug", "")
  if not isinstance(slug, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", slug):
    raise ValueError("publication requires a safe feature slug")
  defaults = {key: "docs/loop-spec/features/{}/{}".format(slug, name)
        for key, name in (("spec", "SPEC.md"), ("plan", "PLAN.md"),
                 ("verification", "VERIFICATION.md"), ("patterns", "PATTERNS.md"))} if root else {}
  defaults["tasks"] = "tasks.json"
  known = dict(defaults)
  known.update({key: value for key, value in state.get("artifacts", {}).items()
         if key in ("spec", "plan", "verification", "patterns", "tasks") and value})
  if registry:
    known.update(registry)
  for key, value in known.items():
    if not isinstance(value, str) or not value:
      raise ValueError("artifact registry requires relative path strings")
    relative = Path(value)
    if ".." in relative.parts:
      raise ValueError("artifact path contains traversal")
    if relative.is_absolute():
      roots = [directory]
      if root:
        roots.append(safe_path(root, "docs/loop-spec/features/" + slug))
      path = None
      for allowed in roots:
        for alias in (allowed, allowed.resolve()):
          try:
            name = relative.relative_to(alias)
          except ValueError:
            continue
          path = safe_path(alias, str(name))
          break
        if path is not None:
          break
      if path is None:
        raise ValueError("absolute artifact path escapes the feature roots")
    elif "/" not in value or (registry and key in registry and not value.startswith("docs/")):
      path = safe_path(directory, value)
    else:
      prefix = Path("docs/loop-spec/features") / slug
      if prefix not in relative.parents:
        raise ValueError("artifact path escapes the feature artifact root")
      if root is None:
        raise ValueError("repository artifact requires a workspace root")
      path = safe_path(root, value)
    if (path.name in ("feature.json", "feature.json.bak") or path.name.startswith(".")
        or any(part in ("publication-staging", "publication-generations", "migration-generations") for part in Path(value).parts)):
      raise ValueError("state and internal paths cannot be artifacts")
    paths[key] = path
  return paths


def capture_locked(directory, registry=None):
  refuse_pending(directory)
  state = load_state(directory)
  publication = state.get("artifactPublication")
  if publication is None:
    raise ValueError("capture requires initialized artifactPublication")
  return {"version": 1, "generation": publication["generation"],
      "stateHash": digest(directory / "feature.json"),
      "inputs": {key: {"path": str(path), "hash": digest(path)}
           for key, path in sorted(artifact_paths(directory, state, registry).items())}}


def stage(directory, name, content):
  """Return a relative staged source for bytes generated by a producer."""
  if not isinstance(content, bytes) or len(content) > 16 * 1024 * 1024:
    raise ValueError("staging requires at most 16 MiB of bytes")
  relative = str(Path("publication-staging") / name)
  target = safe_path(directory, relative)
  target.parent.mkdir(parents=True, exist_ok=True)
  publish(target, content)
  return relative


def journal_write(path, value):
  publish(path, (json.dumps(value, sort_keys=True) + "\n").encode())


def publish_locked(directory, token, manifest, registry=None, failure=None, allowed_updates=None):
  current = capture_locked(directory, registry)
  if (not isinstance(token, dict) or type(token.get("version")) is not int
      or type(token.get("generation")) is not int or token != current):
    raise ValueError("stale publication token; discard the staged result")
  if not isinstance(manifest, dict) or set(manifest) != {"version", "files", "updates"} or type(manifest["version"]) is not int or manifest["version"] != 1:
    raise ValueError("invalid publication manifest")
  if not isinstance(manifest["files"], list) or not isinstance(manifest["updates"], list):
    raise ValueError("manifest files and updates must be arrays")
  if len(manifest["files"]) > 256 or len(manifest["updates"]) > 256:
    raise ValueError("transaction exceeds 256 files or updates")
  previous = state_snapshot(directory)
  state = load_state(directory)
  paths = artifact_paths(directory, state, registry)
  replacements = []
  total_size = 0
  seen = set()
  for entry in manifest["files"]:
    if not isinstance(entry, dict) or set(entry) != {"source", "target"}:
      raise ValueError("invalid manifest file")
    target = paths.get(entry["target"])
    source = safe_path(directory, entry["source"])
    if target is None or Path(entry["source"]).parts[0] != "publication-staging" or not source.is_file():
      raise ValueError("file requires a staged source and registered artifact target")
    if target in seen or source == target:
      raise ValueError("duplicate or overlapping artifact target")
    seen.add(target)
    if source.stat().st_size > 16 * 1024 * 1024 or (target.exists() and target.stat().st_size > 16 * 1024 * 1024):
      raise ValueError("publication file exceeds 16 MiB")
    content = read_bounded(source)
    total_size += len(content) + (target.stat().st_size if target.exists() else 0)
    if total_size > 64 * 1024 * 1024:
      raise ValueError("transaction exceeds 64 MiB")
    replacements.append((target, content))
  permitted = {"warnings"} if allowed_updates is None else set(allowed_updates)
  for update in manifest["updates"]:
    if not isinstance(update, dict) or set(update) != {"path", "value"}:
      raise ValueError("invalid state update")
    dot_path = update["path"]
    if not isinstance(dot_path, str) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*", dot_path):
      raise ValueError("invalid update path")
    if dot_path not in permitted or dot_path.split(".")[0] in ("artifactPublication", "specApproval", "currentGate", "gateHistory"):
      raise ValueError("protected state field: " + dot_path)
    state = prepare_state(directory, json.dumps(state).encode(), "set", update["value"], dot_path.split("."))
  if artifact_paths(directory, state, registry) != paths:
    raise ValueError("publication updates cannot redirect registered targets")
  state["artifactPublication"]["generation"] += 1
  transaction = uuid.uuid4().hex
  base = safe_path(directory, "publication-generations")
  backup = safe_path(directory, "publication-generations/" + transaction)
  backup.mkdir(parents=True)
  entries = []
  journal_bytes = 0
  state_content = (json.dumps(state, indent=2, ensure_ascii=False, allow_nan=False) + "\n").encode("utf-8")
  for index, (target, content) in enumerate(replacements + [(directory / "feature.json", state_content)]):
    original = read_bounded(target) if target.exists() else None
    journal_bytes += len(content) + (len(original) if original is not None else 0)
    if journal_bytes > 64 * 1024 * 1024:
      raise ValueError("transaction originals and replacements exceed 64 MiB")
    name = str(index)
    if original is not None:
      publish(backup / name, original)
      os.chmod(backup / name, 0o400)
    entries.append({"target": next((key for key, value in paths.items() if value == target), "__state__"), "backup": name if original is not None else None,
            "before": hashlib.sha256(original).hexdigest() if original is not None else None, "after": hashlib.sha256(content).hexdigest(), "mode": stat.S_IMODE(target.stat().st_mode) if target.exists() else None})
  if capture_locked(directory, registry) != current:
    raise ValueError("publication inputs changed during staging")
  journal = {"version": 1, "id": transaction, "generation": current["generation"], "entries": entries}
  journal_write(base / "active.json", journal)
  persist(directory)
  if failure:
    failure("staging")
  for index, (target, content) in enumerate(replacements):
    target.parent.mkdir(parents=True, exist_ok=True)
    publish(target, content)
    persist(directory)
    if failure:
      failure(str(index + 1))
  write_state_locked(directory, state, previous)
  persist(directory)
  if failure:
    failure("state")
  os.replace(base / "active.json", backup / "committed.json")
  sync_directory(backup)
  sync_directory(base)
  persist(directory)
  return capture_locked(directory, registry)


def recover_locked(directory, registry=None):
  base = safe_path(directory, "publication-generations")
  active = safe_path(directory, "publication-generations/active.json")
  journal = parse_json(read_bounded(active))
  state = load_state(directory)
  allowed = artifact_paths(directory, state, registry)
  allowed["__state__"] = directory / "feature.json"
  if (not isinstance(journal, dict) or journal.get("version") != 1
      or type(journal.get("version")) is not int
      or type(journal.get("generation")) is not int
      or not re.fullmatch(r"[0-9a-f]{32}", journal.get("id", ""))):
    raise ValueError("invalid recovery journal")
  entries = journal.get("entries")
  if not isinstance(entries, list) or not 1 <= len(entries) <= 257:
    raise ValueError("invalid recovery entries")
  targets = [entry.get("target") for entry in entries if isinstance(entry, dict)]
  if (len(targets) != len(entries) or any(not isinstance(target, str) for target in targets)
      or len(set(targets)) != len(targets) or "__state__" not in targets):
    raise ValueError("recovery requires unique targets and one state original")
  backup = safe_path(base, journal["id"])
  for entry in journal["entries"]:
    target = allowed.get(entry["target"])
    if target is None:
      raise ValueError("recovery target is not registered")
    accepted = [entry["before"], entry["after"]]
    if entry["target"] == "__state__":
      accepted.append(journal.get("recoveredStateHash"))
    if digest(target) not in accepted:
      raise ValueError("recovery refuses changed target: {}".format(target))
    if entry["backup"] is not None:
      if type(entry["mode"]) is not int or not 0 <= entry["mode"] <= 0o777:
        raise ValueError("invalid recovery permission")
      original = safe_path(backup, entry["backup"])
      if digest(original) != entry["before"]:
        raise ValueError("recovery backup hash mismatch")
  generation = journal.get("recoveryGeneration")
  if generation is None:
    generation = max(state["artifactPublication"]["generation"], journal["generation"]) + 1
  elif (type(generation) is not int or generation <= journal["generation"]
        or generation < state["artifactPublication"]["generation"]):
    raise ValueError("invalid recovery generation")
  original_state = next(entry for entry in journal["entries"] if entry["target"] == "__state__")
  restored = parse_json(read_bounded(safe_path(backup, original_state["backup"])))
  restored["artifactPublication"]["generation"] = generation
  restored_content = (json.dumps(restored, indent=2, ensure_ascii=False, allow_nan=False) + "\n").encode("utf-8")
  recovered_hash = hashlib.sha256(restored_content).hexdigest()
  if "recoveryGeneration" in journal and journal.get("recoveredStateHash") != recovered_hash:
    raise ValueError("recovery state does not match its durable selection")
  journal["recoveredStateHash"] = recovered_hash
  journal["recoveryGeneration"] = generation
  journal_write(active, journal)
  persist(directory)
  for entry in journal["entries"]:
    if entry["target"] == "__state__":
      continue
    target = allowed[entry["target"]]
    if entry["backup"] is None:
      if target.exists():
        target.unlink()
    else:
      publish(target, read_bounded(safe_path(backup, entry["backup"])))
      os.chmod(target, entry["mode"])
  write_state_locked(directory, restored, None)
  os.replace(active, backup / "recovered.json")
  sync_directory(backup)
  sync_directory(base)
  persist(directory)
  return capture_locked(directory, registry)


def main(args, failure=None, allowed_updates=None):
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument("operation", choices=("capture", "publish", "recover"))
  parser.add_argument("--feature-dir", required=True)
  parser.add_argument("--token")
  parser.add_argument("--manifest")
  options = parser.parse_args(args)
  directory = Path(os.path.abspath(options.feature_dir))
  with locked_feature(directory):
    if options.operation == "capture":
      result = capture_locked(directory)
    elif options.operation == "recover":
      result = recover_locked(directory)
    else:
      if not options.token or not options.manifest:
        raise ValueError("publish requires --token and --manifest")
      result = publish_locked(directory, parse_json(read_bounded(Path(options.token))), parse_json(read_bounded(Path(options.manifest))), failure=failure, allowed_updates=allowed_updates)
  print(json.dumps(result, sort_keys=True))
  return 0


if __name__ == "__main__":
  try:
    sys.exit(main(sys.argv[1:]))
  except (ValueError, KeyError, TypeError) as exc:
    print("artifact-publication: {}".format(exc), file=sys.stderr)
    sys.exit(1)
  except OSError as exc:
    print("artifact-publication: I/O failure: {}".format(exc), file=sys.stderr)
    sys.exit(2)
