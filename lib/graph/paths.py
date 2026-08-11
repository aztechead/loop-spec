"""paths.py — path resolution shared by the graph engine and validator.

A graph declares probe, body, and subgraph locations as repo-relative paths, but
an absolute path must survive untouched. Both modules resolve those the same way;
this is the one definition so the rule cannot drift between the program that
CHECKS a path exists and the program that RUNS it.
"""

import os


def repo_path(value, repo_root):
    """Resolve a graph-declared path against repo_root, leaving absolutes alone."""
    return value if os.path.isabs(value) else os.path.join(repo_root, value)
