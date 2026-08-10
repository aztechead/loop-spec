#!/usr/bin/env python3
"""
claimant.py -- production out-of-process consumer for the loop-spec handoff
port (skills/shared/handoff-port.md). This is a real worker process, not a
test helper: it finds claimable work, claims it, does it, verifies it, and
completes it -- or releases the claim and gets out of the way. It shares no
in-memory state with the loop-spec session that put the work on the port;
everything it needs comes from the bundle plus the CLI args below.

It talks to the port ONLY through lib/graph/port.sh, never by touching the
adapter's storage directly -- that indirection is the entire point of the
port (an integrator's LOOP_SPEC_PORT can point anywhere; this process never
knows the difference). See README.md alongside this file: reference
consumer, not a supported product surface.

This reference implementation knows how to do exactly one kind of task
(deploy the sibling app.py, examples/foreign-claimant/README.md). A real
production consumer would dispatch on bundle["node"] / bundle["task"] /
bundle["brief"] to pick an implementation; this one only has the one, which
is enough to prove the port has an end-to-end consumer.

Usage:
  claimant.py --repo-root DIR --feature-dir DIR [--owner NAME] [--ttl SECONDS]

Exit 0: claimed a bundle, did the work, verify passed, complete accepted it.
Exit 1: no claimable work, or work was claimed but not completed (bad
        bundle, verify failed, complete rejected) -- the claim is released
        either way, so a failed attempt never leaks a lease.
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path


def run_port(port_sh, args):
    return subprocess.run(
        ["bash", str(port_sh), *args], capture_output=True, text=True
    )


def cksum_hash(path):
    # Same algorithm lib/graph/handoff.sh and lib/graph/port-local.sh use to
    # derive/check stateHash: `cksum <file> | awk '{print $1"-"$2}'`.
    with open(path, "rb") as fh:
        out = subprocess.run(
            ["cksum"], stdin=fh, capture_output=True, text=True, check=True
        )
    checksum, size = out.stdout.split()[:2]
    return f"{checksum}-{size}"


def do_the_work(repo_root, bundle):
    """Write the deliverable the bundle names. Returns the resolved path."""
    files = bundle.get("files") or []
    if not files:
        raise RuntimeError(
            "bundle names no files; cannot act without out-of-band knowledge"
        )
    target = (repo_root / files[0]).resolve()
    target.parent.mkdir(parents=True, exist_ok=True)
    source = Path(__file__).resolve().parent / "app.py"
    target.write_bytes(source.read_bytes())
    return target


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", required=True, help="where lib/graph/port.sh lives and files[] resolve against")
    parser.add_argument("--feature-dir", required=True, help="passed through to `complete`")
    parser.add_argument("--owner", default=f"claimant-{os.getpid()}")
    parser.add_argument("--ttl", type=int, default=120)
    args = parser.parse_args(argv)

    repo_root = Path(args.repo_root).resolve()
    port_sh = repo_root / "lib" / "graph" / "port.sh"
    if not port_sh.is_file():
        print(f"claimant: no port.sh at {port_sh}", file=sys.stderr)
        return 1

    listing = run_port(port_sh, ["list", "--claimable"])
    if listing.returncode != 0:
        print(f"claimant: list --claimable failed: {listing.stderr}", file=sys.stderr)
        return 1
    ids = [line.strip() for line in listing.stdout.splitlines() if line.strip()]
    if not ids:
        print("claimant: no claimable work")
        return 1

    claimed_id = None
    for candidate in ids:
        r = run_port(port_sh, ["claim", candidate, args.owner, str(args.ttl)])
        if r.returncode == 0:
            claimed_id = candidate
            break
    if claimed_id is None:
        print("claimant: every claimable id was claimed by someone else first", file=sys.stderr)
        return 1

    print(f"claimant: claimed {claimed_id} as {args.owner}")
    try:
        got = run_port(port_sh, ["get", claimed_id])
        if got.returncode != 0:
            print(f"claimant: get {claimed_id} failed: {got.stderr}", file=sys.stderr)
            return 1
        bundle = json.loads(got.stdout)

        verify_command = bundle.get("verifyCommand") or ""
        if not verify_command:
            print(f"claimant: bundle {claimed_id} has no verifyCommand; refusing to complete unverified work", file=sys.stderr)
            return 1

        target = do_the_work(repo_root, bundle)
        print(f"claimant: wrote {target} ({bundle.get('brief') or 'no brief given'})")

        verify = subprocess.run(["bash", "-c", verify_command], capture_output=True, text=True)
        if verify.returncode != 0:
            print(
                f"claimant: verify failed, refusing to complete:\n{verify.stdout}{verify.stderr}",
                file=sys.stderr,
            )
            return 1
        print("claimant: verify passed")

        # Honestly-derived state hash, for the record: computed fresh from
        # the same feature-dir we're about to hand to `complete`, the same
        # way handoff.sh/port-local.sh derive it. `complete` never trusts
        # this field -- it re-derives its own copy and compares -- so this
        # can't be forged to pass; it's here so the result artifact tells
        # the truth rather than parroting the bundle's captured hash.
        feature_json = Path(args.feature_dir) / "feature.json"
        state_hash = cksum_hash(feature_json) if feature_json.is_file() else None
        result = {"ok": True, "owner": args.owner, "files": bundle.get("files"), "stateHash": state_hash}
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump(result, f)
            result_path = f.name
        try:
            completed = run_port(port_sh, ["complete", claimed_id, result_path, args.feature_dir])
        finally:
            os.unlink(result_path)
        if completed.returncode != 0:
            print(f"claimant: complete rejected: {completed.stderr}", file=sys.stderr)
            return 1
        print(f"claimant: {completed.stdout.strip()}")
        return 0
    except Exception as exc:  # noqa: BLE001 -- any failure here means "refuse and release", not crash
        print(f"claimant: aborting, releasing claim: {exc}", file=sys.stderr)
        return 1
    finally:
        # Best-effort and unconditional: after a successful complete the
        # adapter has already cleared the claim (a harmless no-op here);
        # after any failure this is what stops the lease from leaking until
        # its TTL expires on its own.
        run_port(port_sh, ["release", claimed_id])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
