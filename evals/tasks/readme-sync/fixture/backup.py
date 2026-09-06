#!/usr/bin/env python3
"""Copy a directory tree to a destination, skipping excluded patterns."""
import argparse
import fnmatch
import os
import shutil
import sys


def should_skip(rel, patterns):
    return any(fnmatch.fnmatch(rel, p) for p in patterns)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, help="directory to copy from")
    parser.add_argument("--dest", required=True, help="directory to copy into")
    parser.add_argument("--exclude", action="append", default=[],
                        help="glob pattern to skip (repeatable)")
    parser.add_argument("--dry-run", action="store_true",
                        help="print what would be copied and copy nothing")
    parser.add_argument("--verbose", action="store_true", help="print each copied file")
    args = parser.parse_args(argv)

    for root, _dirs, files in os.walk(args.source):
        for name in files:
            src = os.path.join(root, name)
            rel = os.path.relpath(src, args.source)
            if should_skip(rel, args.exclude):
                continue
            dst = os.path.join(args.dest, rel)
            if args.dry_run or args.verbose:
                print(f"{src} -> {dst}")
            if not args.dry_run:
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                shutil.copy2(src, dst)
    return 0


if __name__ == "__main__":
    sys.exit(main())
