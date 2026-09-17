#!/usr/bin/env python3
"""Small, bounded OKF v0.2 reader and validator."""
from __future__ import annotations
import os
import re
import codecs
from typing import Any, Dict, Tuple
import yaml

MAX_HEADER_BYTES = 64 * 1024
MAX_YAML_NODES = 10000
MAX_YAML_ALIASES = 1000
MAX_YAML_DEPTH = 100

class OKFError(ValueError):
    """Raised when an OKF document violates the required baseline contract."""

class _BoundedLoader(yaml.SafeLoader):
    nodes_seen = 0
    aliases_seen = 0
    depth = 0
    def compose_node(self, parent, index):
        self.nodes_seen += 1
        if self.nodes_seen > MAX_YAML_NODES:
            raise OKFError("frontmatter has too many YAML nodes")
        if self.check_event(yaml.events.AliasEvent):
            self.aliases_seen += 1
            if self.aliases_seen > MAX_YAML_ALIASES:
                raise OKFError("frontmatter has too many YAML aliases")
        self.depth += 1
        if self.depth > MAX_YAML_DEPTH:
            raise OKFError("frontmatter nesting is too deep")
        try:
            return super().compose_node(parent, index)
        finally:
            self.depth -= 1

    def construct_mapping(self, node, deep=False):
        mapping = {}
        for key_node, value_node in node.value:
            key = self.construct_object(key_node, deep=deep)
            try: duplicate = key in mapping
            except TypeError as exc: raise OKFError("YAML mapping key must be hashable") from exc
            if duplicate:
                raise OKFError("duplicate YAML key: %s" % key)
            mapping[key] = self.construct_object(value_node, deep=deep)
        return mapping

def _yaml_mapping(source: str) -> Dict[str, Any]:
    try:
        loader = _BoundedLoader(source)
        try:
            value = loader.get_single_data()
        finally:
            loader.dispose()
    except OKFError:
        raise
    except yaml.YAMLError as exc:
        raise OKFError("invalid YAML frontmatter: %s" % exc) from exc
    if not isinstance(value, dict):
        raise OKFError("frontmatter must be a YAML mapping")
    return value

def _yaml_metadata(source: str) -> Dict[str, Any]:
    value = _yaml_mapping(source)
    if "type" not in value or not isinstance(value["type"], str) or not value["type"].strip():
        raise OKFError("frontmatter needs a non-empty type")
    return value

def _split_header(text: str) -> Tuple[str, str]:
    if not (text.startswith("---\n") or text.startswith("---\r\n")):
        raise OKFError("document needs YAML frontmatter")
    match = re.search(r"^---[ \t]*(?:\r?\n|$)", text[4:], re.MULTILINE)
    if match is None:
        raise OKFError("frontmatter is not closed")
    end = 4 + match.end()
    header = text[4:end-len(match.group(0))].replace("\r\n", "\n")
    return header, text[end:]

def split_document(text: str) -> Tuple[Dict[str, Any], str]:
    if not isinstance(text, str):
        raise TypeError("document must be text")
    header, body = _split_header(text)
    if len(header.encode("utf-8")) + 8 > MAX_HEADER_BYTES:
        raise OKFError("frontmatter exceeds %d-byte limit" % MAX_HEADER_BYTES)
    return _yaml_metadata(header), body

def _read_header_stream(fh):
    chunks, total = [], 0
    while total <= MAX_HEADER_BYTES:
        chunk = fh.readline(MAX_HEADER_BYTES + 1 - total)
        if not chunk: break
        chunks.append(chunk); total += len(chunk)
        if total > MAX_HEADER_BYTES:
            raise OKFError("frontmatter exceeds %d-byte limit" % MAX_HEADER_BYTES)
        if len(chunks) >= 2 and chunk.rstrip(b"\r\n").rstrip(b" \t") == b"---":
            raw = b"".join(chunks)
            try: return raw.decode("utf-8")
            except UnicodeDecodeError as exc: raise OKFError("document is not valid UTF-8") from exc
    if not chunks: raise OKFError("document needs YAML frontmatter")
    try: b"".join(chunks).decode("utf-8")
    except UnicodeDecodeError as exc: raise OKFError("document is not valid UTF-8") from exc
    raise OKFError("frontmatter is not closed")

def read_metadata(path) -> Dict[str, Any]:
    with open(os.fspath(path), "rb") as fh:
        header = _read_header_stream(fh)
    front, _ = _split_header(header)
    return _yaml_metadata(front)

def read_document(path):
    try:
        with open(path, "rb") as fh:
            header = _read_header_stream(fh)
            front, _ = _split_header(header)
            metadata = _yaml_metadata(front)
            body = fh.read().decode("utf-8")
        return metadata, body
    except UnicodeDecodeError as exc:
        raise OKFError("document is not valid UTF-8") from exc

def validate_utf8(path, chunk_size=65536):
    decoder = codecs.getincrementaldecoder("utf-8")()
    try:
        with open(path, "rb") as fh:
            while True:
                chunk = fh.read(chunk_size)
                if not chunk: break
                decoder.decode(chunk)
            decoder.decode(b"", final=True)
    except UnicodeDecodeError as exc:
        raise OKFError("document is not valid UTF-8") from exc

def render_document(metadata: Dict[str, Any], body: str) -> str:
    if not isinstance(metadata, dict): raise TypeError("metadata must be a mapping")
    if not isinstance(body, str): raise TypeError("body must be text")
    dumped = yaml.safe_dump(metadata, sort_keys=False, allow_unicode=True).rstrip("\n")
    if len(dumped.encode("utf-8")) + 8 > MAX_HEADER_BYTES:
        raise OKFError("rendered frontmatter exceeds %d-byte limit" % MAX_HEADER_BYTES)
    _yaml_metadata(dumped)
    return "---\n" + dumped + "\n---\n" + body

def normalize_verified(metadata: Dict[str, Any]) -> Dict[str, Any]:
    result = dict(metadata)
    if isinstance(result.get("verified"), dict):
        result["verified"] = [result["verified"]]
    return result

def validate_index(path, root=False):
    try:
        with open(path, "rb") as fh:
            prefix = fh.read(5)
            fh.seek(0)
            if prefix.startswith(b"---\n") or prefix.startswith(b"---\r\n"):
                if not root: raise OKFError("non-root index.md must not have frontmatter")
                header = _read_header_stream(fh)
                metadata = _yaml_mapping(_split_header(header)[0])
                if set(metadata) != {"okf_version"} or metadata["okf_version"] != "0.2":
                    raise OKFError("root index.md frontmatter may only declare okf_version: '0.2'")
            # Root frontmatter is optional; when present it was checked above.
            heading_seen = False
            while True:
                line = fh.readline(MAX_HEADER_BYTES + 1)
                if not line: break
                if len(line) > MAX_HEADER_BYTES: raise OKFError("index.md line exceeds bounded limit")
                decoded = line.decode("utf-8")
                if not heading_seen and decoded.strip():
                    if not decoded.lstrip().startswith("#"): raise OKFError("index.md needs a markdown section heading")
                    heading_seen = True
            if heading_seen: return
    except UnicodeDecodeError as exc: raise OKFError("index.md is not valid UTF-8") from exc
    raise OKFError("index.md needs a markdown section heading")

def validate_log(path):
    try:
        with open(path, "rb") as fh:
            while True:
                raw = fh.readline(MAX_HEADER_BYTES + 1)
                if not raw: break
                if len(raw) > MAX_HEADER_BYTES: raise OKFError("log.md line exceeds bounded limit")
                line = raw.decode("utf-8")
                match = re.match(r"^##\s+(\S+)\s*$", line)
                if match and not re.fullmatch(r"\d{4}-\d{2}-\d{2}", match.group(1)):
                    raise OKFError("log.md date headings must use YYYY-MM-DD")
    except UnicodeDecodeError as exc: raise OKFError("log.md is not valid UTF-8") from exc
