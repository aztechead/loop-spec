#!/usr/bin/env python3
"""Preserve documents outside the branch and restore baseline docs/index together.

store receives the caller's original token and returns its own accepted refresh.
recover resolves journal keys within received roots; journals cannot grant roots.

store's manifest.json records stateCapturedAtGeneration: the feature's generation
at ingress, before this transaction's own publish bumps it and records
artifactSink. The archived state/feature.json under the sink destination is that
pre-publication snapshot, one generation behind the live feature.json once store
is accepted.

Both store and recover take Git's own index lock (index_lock) before touching the
index, and refuse rather than clear a lock they do not own: a lock left behind by
a Git process that died mid-write makes every later store/recover exit 1 with
"Git index is locked" until an operator confirms no Git process still owns it and
removes the file themselves (`git`'s own guidance for a stale index.lock).
"""
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import uuid

from artifact_publication import (capture_locked, digest, locked_feature,
                 publish_locked, recover_locked, safe_path, stage)
from feature_read import load_state
from feature_write import (begin_operation, parse_json, participant_registry,
               publish, read_bounded)


def git(root, *args, **kwargs):
  with subprocess.Popen(["git", "-C", str(root)] + list(args),
              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, **kwargs) as process:
    output = process.stdout.read(16 * 1024 * 1024 + 1)
    if len(output) > 16 * 1024 * 1024:
      process.kill()
      process.wait()
      raise ValueError("artifact sink Git output exceeds 16 MiB")
    if process.wait():
      raise ValueError("artifact sink Git operation failed: " + output.decode("utf-8", "replace").strip())
    return output


@contextmanager
def index_lock(index):
  path = index.with_name(index.name + ".lock")
  try:
    descriptor = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
  except FileExistsError as exc:
    raise ValueError("Git index is locked; finish its owning Git operation before artifact sink recovery") from exc
  try:
    os.close(descriptor)
    yield
  finally:
    path.unlink()


def layout(directory, root, sink_root):
  directory, root = Path(directory).absolute(), Path(root).absolute()
  if directory.is_symlink() or root.is_symlink():
    raise ValueError("artifact sink refuses symlink roots")
  if root.resolve() not in directory.resolve().parents:
    raise ValueError("feature directory is outside the repository")
  state = load_state(directory)
  slug = state.get("slug", "")
  if not isinstance(slug, str) or not re.fullmatch(r"[a-z0-9][a-z0-9._-]*", slug):
    raise ValueError("feature slug is missing or unsafe")
  common = Path(os.fsdecode(git(root, "rev-parse", "--git-common-dir")).strip())
  common = (root / common).resolve() if not common.is_absolute() else common.resolve()
  index = Path(os.fsdecode(git(root, "rev-parse", "--git-path", "index")).strip())
  index = root / index if not index.is_absolute() else index
  if index.is_symlink():
    raise ValueError("artifact sink refuses a symlinked Git index")
  index = index.resolve()
  sink_root = Path(sink_root) if sink_root else common / "loop-spec/artifacts"
  sink_root = root / sink_root if not sink_root.is_absolute() else sink_root
  if sink_root.is_symlink():
    raise ValueError("artifact sink refuses a symlinked store")
  sink_root = sink_root.resolve()
  if (sink_root == root or root in sink_root.parents) and common not in sink_root.parents:
    raise ValueError("artifact store must be outside the working tree or inside Git private storage")
  return directory, root, sink_root, common, index, slug, state


def files_under(root, state=False):
  if root.is_symlink():
    raise ValueError("artifact sink refuses a symlinked source tree")
  result = []
  if not root.exists():
    return result
  for directory, folders, files in os.walk(str(root), followlinks=False):
    folders[:] = sorted(name for name in folders if not (state and name == "publication-staging"))
    for name in folders + files:
      if (Path(directory) / name).is_symlink():
        raise ValueError("artifact sink refuses a symlinked source: " + str(Path(directory) / name))
    for name in sorted(files):
      if state and name.endswith(".lock"):
        continue
      path = Path(directory) / name
      if not path.is_file():
        raise ValueError("artifact sink source is not a regular file: " + str(path))
      result.append(path)
      if len(result) > 256:
        raise ValueError("artifact sink source exceeds 256 files")
  return sorted(result)


def registered_targets(directory, root, sink_root, index, slug, keys):
  registry = dict(participant_registry(directory) or {})
  docs = safe_path(root, "docs/loop-spec/features/" + slug)
  for key in keys:
    if key in ("spec", "plan", "patterns", "verification", "tasks"):
      continue
    if key == "sink_index":
      registry[key] = str(index)
    elif key.startswith("sink_doc:"):
      registry[key] = str(safe_path(docs, key.split(":", 1)[1]))
    elif key.startswith("sink_file:"):
      relative = key.split(":", 1)[1]
      head, separator, name = relative.partition("/")
      if not separator or not re.fullmatch(r"[0-9a-f]{40,64}", head):
        raise ValueError("invalid sink journal source revision")
      if name != "manifest.json" and not name.startswith(("artifacts/", "state/")):
        raise ValueError("invalid sink journal destination")
      registry[key] = str(safe_path(sink_root, slug + "/" + relative))
    else:
      raise ValueError("unknown artifact sink journal target: " + key)
  return registry


def store(directory, root, sink_root=None, token=None, failure=None):
  directory = Path(directory).absolute()
  ingress = begin_operation(directory, token)
  if ingress is None:
    raise ValueError("artifact sink requires an incomplete schema-7 feature")
  directory, root, sink_root, common, index, slug, state = layout(directory, root, sink_root)
  base = state.get("baseSha")
  if not isinstance(base, str) or not base:
    raise ValueError("artifact sink requires the recorded base SHA")
  git(root, "rev-parse", "--verify", base + "^{commit}")
  head = git(root, "rev-parse", "HEAD").decode().strip()
  docs_rel = "docs/loop-spec/features/" + slug
  docs = safe_path(root, docs_rel)
  destination = safe_path(sink_root, slug + "/" + head)
  generic = participant_registry(directory)
  with locked_feature(directory):
    if ingress != capture_locked(directory, generic):
      raise ValueError("stale publication token before artifact sink input capture")
    baseline = {}
    for entry in git(root, "ls-tree", "-r", "-z", base, "--", docs_rel).split(b"\0"):
      if not entry:
        continue
      metadata, name = entry.split(b"\t", 1)
      mode, kind, oid = metadata.split()
      if kind != b"blob" or mode not in (b"100644", b"100755"):
        raise ValueError("artifact sink baseline contains a non-regular document")
      relative = os.fsdecode(name)[len(docs_rel) + 1:]
      baseline[relative] = {"oid": oid.decode(), "executable": mode == b"100755"}
      if len(baseline) > 256:
        raise ValueError("artifact sink baseline exceeds 256 documents")
    doc_files = files_under(docs)
    if (destination / "manifest.json").exists():
      manifest = parse_json(read_bounded(destination / "manifest.json"))
      if (manifest.get("sourceHead") != head or manifest.get("slug") != slug
          or manifest.get("artifactsInPr") is not False or not isinstance(manifest.get("files"), dict)
          or state.get("artifactSink") != {"mode":"store", "manifest":slug + "/" + head + "/manifest.json"}):
        raise ValueError("artifact sink destination exists without matching accepted state")
      for name, expected in manifest["files"].items():
        if digest(safe_path(destination, name)) != expected:
          raise ValueError("artifact sink archived file changed: " + name)
      if set(str(path.relative_to(docs)) for path in doc_files) != set(baseline):
        raise ValueError("artifact sink documents changed after accepted storage")
      git(root, "diff", "--exit-code", base, "--", docs_rel)
      return destination, ingress
    if destination.exists() and files_under(destination):
      raise ValueError("artifact sink destination exists without a matching manifest")
    sink_root.mkdir(parents=True, exist_ok=True)
    staging = safe_path(directory, "publication-staging")
    staging.mkdir(exist_ok=True)
    state_files = files_under(directory, state=True)
    sources = {}
    size = 0
    for path in doc_files + state_files:
      content = read_bounded(path)
      size += len(content)
      if size > 64 * 1024 * 1024:
        raise ValueError("artifact sink sources exceed 64 MiB")
      sources[path] = content
    desired = {}
    hashes = {}
    for path, content in sources.items():
      relative = ("artifacts/" + str(path.relative_to(docs))) if path in doc_files else ("state/" + str(path.relative_to(directory)))
      desired["sink_file:" + head + "/" + relative] = content
      hashes[relative] = hashlib.sha256(content).hexdigest()
    for relative in set(str(path.relative_to(docs)) for path in doc_files) | set(baseline):
      desired["sink_doc:" + relative] = None
    manifest = {"schema":1, "slug":slug, "baseSha":base, "sourceHead":head,
          "createdAt":datetime.now(timezone.utc).isoformat(), "artifactsInPr":False, "files":hashes,
          # The archived state/feature.json is read (via state_files above) before this
          # transaction's own publish_locked call bumps the generation and records
          # artifactSink, so it is always one generation behind the live file once
          # accepted. Recorded explicitly rather than left to be inferred from a diff.
          "stateCapturedAtGeneration": ingress["generation"]}
    desired["sink_file:" + head + "/manifest.json"] = (json.dumps(manifest, sort_keys=True) + "\n").encode()
    desired["sink_index"] = None
    registry = registered_targets(directory, root, sink_root, index, slug, desired)
    expanded = capture_locked(directory, registry, external_roots=[sink_root, common])
  for relative, entry in baseline.items():
    desired["sink_doc:" + relative] = git(root, "cat-file", "blob", entry["oid"])
  with tempfile.TemporaryDirectory(prefix="sink-index-", dir=str(staging)) as temporary:
    prepared = Path(temporary) / "index"
    if index.exists():
      prepared.write_bytes(read_bounded(index))
    environment = dict(os.environ, GIT_INDEX_FILE=str(prepared))
    if not index.exists():
      git(root, "read-tree", "--empty", env=environment)
    git(root, "rm", "-r", "-f", "--cached", "--ignore-unmatch", "--", docs_rel, env=environment)
    if baseline:
      git(root, "restore", "--source", base, "--staged", "--", docs_rel, env=environment)
    desired["sink_index"] = read_bounded(prepared)
    files = [{"source":stage(directory, "sink/" + uuid.uuid4().hex, content) if content is not None else None,
          "target":key} for key, content in desired.items()]
  if failure:
    failure("prepared")
  with locked_feature(directory), index_lock(index):
    if git(root, "rev-parse", "HEAD").decode().strip() != head:
      raise ValueError("artifact sink candidate HEAD changed during preparation")
    if files_under(docs) != doc_files or any(digest(path) != hashlib.sha256(content).hexdigest() for path, content in sources.items()):
      raise ValueError("stale artifact sink source files changed during preparation")
    publish_locked(directory, expanded, {"version":1, "files":files,
            "updates":[{"path":"artifactSink", "value":{"mode":"store", "manifest":slug + "/" + head + "/manifest.json"}}]},
            registry=registry, external_roots=[sink_root, common], allowed_updates={"artifactSink"}, failure=failure)
    # publish_locked carries a replaced target's permission bits forward from
    # whatever was already on disk (or the tempfile default when nothing was
    # there), never from Git: an ls-tree mode is not a manifest concept it
    # knows about. Restore the baseline's own executable bit here so a
    # mode-755 document does not silently come back non-executable, whether it
    # was merely stale (candidate had dropped +x) or deleted outright.
    for relative, entry in baseline.items():
      if entry["executable"]:
        os.chmod(safe_path(docs, relative), 0o755)
    return destination, capture_locked(directory, generic)


def recover(directory, root, sink_root=None):
  directory, root, sink_root, common, index, slug, state = layout(directory, root, sink_root)
  with locked_feature(directory), index_lock(index):
    journal = parse_json(read_bounded(safe_path(directory, "publication-generations/active.json")))
    keys = [entry["target"] for entry in journal["entries"] if entry["target"] != "__state__"]
    registry = registered_targets(directory, root, sink_root, index, slug, keys)
    recover_locked(directory, registry, external_roots=[sink_root, common])
    return capture_locked(directory, participant_registry(directory))


def main(args):
  if len(args) != 3 or args[0] not in ("store", "recover"):
    raise ValueError("usage: artifact-sink.sh store|recover <feature_dir> <repo_root>")
  mode = os.environ.get("LOOP_SPEC_ARTIFACTS_IN_PR", "1")
  if mode not in ("0", "1"):
    raise ValueError("LOOP_SPEC_ARTIFACTS_IN_PR must be 0 or 1")
  if args[0] == "store" and mode == "1":
    print("inline")
    return 0
  incoming = os.environ.get("LOOP_SPEC_PUBLICATION_TOKEN")
  output = os.environ.get("LOOP_SPEC_PUBLICATION_TOKEN_OUTPUT")
  if output and incoming and Path(output).resolve() == Path(incoming).resolve():
    raise ValueError("publication token output must differ from the immutable input")
  token = parse_json(read_bounded(Path(incoming))) if incoming else None
  if args[0] == "recover":
    refreshed = recover(args[1], args[2], os.environ.get("LOOP_SPEC_ARTIFACT_DIR"))
    result = "recovered"
  else:
    destination, refreshed = store(args[1], args[2], os.environ.get("LOOP_SPEC_ARTIFACT_DIR"), token=token)
    result = "stored:" + str(destination)
  if output:
    publish(Path(output), (json.dumps(refreshed) + "\n").encode())
  print(result)
  return 0


if __name__ == "__main__":
  try:
    sys.exit(main(sys.argv[1:]))
  except (ValueError, TypeError, KeyError) as exc:
    print("artifact-sink: " + str(exc), file=sys.stderr)
    sys.exit(1)
  except OSError as exc:
    print("artifact-sink: I/O failure: " + str(exc), file=sys.stderr)
    sys.exit(2)
