"""loop-spec 7.x program package: the version every module reports comes from here.

Reads VERSION once from the shipped manifest.toml so the CLI, state files, and tests
never hardcode a version string that could drift from the packaged one.
"""
import tomllib
from pathlib import Path

_MANIFEST = Path(__file__).resolve().parents[2] / "manifest.toml"

with open(_MANIFEST, "rb") as _f:
    VERSION = tomllib.load(_f)["version"]
