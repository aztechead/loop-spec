#!/usr/bin/env python3
"""Count lines, words, and characters in files, like wc."""
import argparse
import sys


def count(path):
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    return {
        "path": path,
        "lines": text.count("\n"),
        "words": len(text.split()),
        "chars": len(text),
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="+")
    args = parser.parse_args(argv)
    for path in args.paths:
        c = count(path)
        print(f"{c['lines']:>8}{c['words']:>8}{c['chars']:>8} {c['path']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
