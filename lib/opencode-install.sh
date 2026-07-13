#!/usr/bin/env bash
# opencode-install.sh — install loop-spec into an opencode (https://opencode.ai)
# config directory, entirely through opencode's NATIVE discovery surfaces:
#
#   skills    -> <config>/skills/<name>        (opencode scans
#                {skill,skills}/**/SKILL.md in every config dir, symlinks
#                followed; loop-spec skills already carry Agent-Skills-standard
#                frontmatter, so they load unmodified)
#   command   -> <config>/commands/loop-debug.md   ({command,commands}/**/*.md;
#                $ARGUMENTS substitution works in both harnesses)
#   plugin    -> <config>/plugins/loop-spec.ts     ({plugin,plugins}/*.{ts,js};
#                the bridge in extensions/opencode/loop-spec.ts — realpaths
#                itself, so a symlink here still finds the package root)
#   agents    -> <config>/agents/loop-spec-<role>.md  (GENERATED: opencode's
#                agent frontmatter differs from Claude Code's, so agents/*.md
#                are converted — description kept, mode: subagent, CC tool
#                allow/deny lists mapped to opencode tool ids. Claude Code
#                model aliases (sonnet/opus) mean nothing to opencode, so
#                agents inherit the session model; pin per-agent models by
#                editing the generated file with a provider/model id.)
#
# Everything except agents is a symlink by default (one clone, updates flow
# through `git pull`); --copy makes physical copies instead. A manifest of
# every path created is written to <config>/loop-spec-install.json so
# uninstall removes exactly what install created.
#
# Usage:
#   opencode-install.sh install   [--project <dir>] [--copy]
#   opencode-install.sh uninstall [--project <dir>]
#   opencode-install.sh status    [--project <dir>]
#
# Target resolution:
#   --project <dir>       -> <dir>/.opencode        (per-project install)
#   OPENCODE_CONFIG_DIR   -> $OPENCODE_CONFIG_DIR   (override, used by tests)
#   default               -> ${XDG_CONFIG_HOME:-~/.config}/opencode  (global)
#
# Exit codes: 0 ok; 1 partial failure (a collision was skipped); 2 bad usage.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

_die2() { echo "opencode-install.sh: $*" >&2; exit 2; }

cmd="${1:-}"
case "$cmd" in install|uninstall|status) ;; *) _die2 "unknown subcommand '${cmd:-}' (install|uninstall|status)" ;; esac
shift

PROJECT=""
COPY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="${2:-}"; [[ -n "$PROJECT" ]] || _die2 "--project needs a directory"; shift 2 ;;
    --copy) COPY=1; shift ;;
    *) _die2 "unknown flag '$1'" ;;
  esac
done

if [[ -n "$PROJECT" ]]; then
  [[ -d "$PROJECT" ]] || _die2 "--project dir does not exist: $PROJECT"
  TARGET="$(cd "$PROJECT" && pwd)/.opencode"
else
  TARGET="${OPENCODE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode}"
fi
MANIFEST="$TARGET/loop-spec-install.json"

# ---------------------------------------------------------------------------
status_cmd() {
  if [[ -f "$MANIFEST" ]]; then
    echo "installed: $TARGET"
    jq -r '"version: \(.version)\nmode: \(.mode)\npaths:", (.created[] | "  \(.)")' "$MANIFEST"
  else
    echo "not installed: $TARGET (no loop-spec-install.json)"
  fi
}

uninstall_cmd() {
  [[ -f "$MANIFEST" ]] || { echo "nothing to uninstall at $TARGET"; return 0; }
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    # Only remove paths inside the target config dir — a corrupt manifest must
    # never be able to point the rm at the repo or the user's home.
    case "$p" in
      "$TARGET"/*) rm -rf "$p" ;;
      *) echo "skip (outside $TARGET): $p" >&2 ;;
    esac
  done < <(jq -r '.created[]' "$MANIFEST")
  rm -f "$MANIFEST"
  echo "uninstalled loop-spec from $TARGET"
}

# place <src> <dst>: symlink (default) or copy; refuses to clobber anything
# that is not already a link/copy owned by a previous loop-spec install.
SKIPPED=0
CREATED=()
place() {
  local src="$1" dst="$2"
  if [[ -e "$dst" || -L "$dst" ]]; then
    # Ours if it is a symlink into the repo, or listed in an old manifest.
    if [[ -L "$dst" && "$(readlink "$dst")" == "$src" ]]; then
      CREATED+=("$dst"); return 0
    fi
    if [[ -f "$MANIFEST" ]] && jq -e --arg p "$dst" '.created | index($p)' "$MANIFEST" >/dev/null 2>&1; then
      rm -rf "$dst"
    else
      echo "skip (exists, not loop-spec's): $dst" >&2
      SKIPPED=1; return 1
    fi
  fi
  mkdir -p "$(dirname "$dst")"
  if [[ "$COPY" == "1" ]]; then
    cp -R "$src" "$dst"
  else
    ln -s "$src" "$dst"
  fi
  CREATED+=("$dst")
}

install_cmd() {
  command -v python3 >/dev/null 2>&1 || _die2 "python3 is required (agent conversion)"
  command -v jq >/dev/null 2>&1 || _die2 "jq is required"
  mkdir -p "$TARGET"

  # 1. Skills — every skills/<name>/ with a SKILL.md (shared/ has none; it is
  #    reference material reached from skill bodies via relative paths).
  local d name
  for d in "$REPO_ROOT"/skills/*/; do
    name="$(basename "$d")"
    [[ -f "$d/SKILL.md" ]] || continue
    place "${d%/}" "$TARGET/skills/$name" || true
  done

  # 2. The one-shot command (loads as /loop-debug; $ARGUMENTS is shared syntax).
  place "$REPO_ROOT/commands/loop-debug.md" "$TARGET/commands/loop-debug.md" || true

  # 3. The bridge plugin.
  place "$REPO_ROOT/extensions/opencode/loop-spec.ts" "$TARGET/plugins/loop-spec.ts" || true

  # 4. Agents — converted, never linked (frontmatter dialects differ).
  mkdir -p "$TARGET/agents"
  local agents_out
  agents_out="$(python3 - "$REPO_ROOT/agents" "$TARGET/agents" <<'PYEOF'
import json, os, re, sys

src_dir, out_dir = sys.argv[1], sys.argv[2]

# CC tool name -> opencode tool id (registry ids, packages/opencode/src/tool).
TOOL_MAP = {
    "Read": "read", "Write": "write", "Edit": "edit", "NotebookEdit": "edit",
    "Bash": "bash", "Grep": "grep", "Glob": "glob",
    "WebFetch": "webfetch", "WebSearch": "websearch",
    "Skill": "skill", "Agent": "task", "Task": "task",
    "AskUserQuestion": "question",
    "TaskCreate": "todowrite", "TaskUpdate": "todowrite",
    "TaskList": "todowrite", "TaskGet": "todowrite",
}
# Deny-by-default set used when a CC agent declares an allow-list.
BUILTINS = ["bash", "edit", "write", "read", "grep", "glob",
            "webfetch", "websearch", "task", "skill", "question", "todowrite"]

def parse_frontmatter(text):
    m = re.match(r"^---\n(.*?)\n---\n(.*)$", text, re.S)
    if not m:
        return None, text
    fm, body = m.group(1), m.group(2)
    data, key = {}, None
    for line in fm.splitlines():
        if re.match(r"^\s*-\s+", line) and key:
            data.setdefault(key, [])
            if isinstance(data[key], list):
                data[key].append(line.split("-", 1)[1].strip())
            continue
        kv = re.match(r"^([A-Za-z][A-Za-z0-9_-]*):\s*(.*)$", line)
        if kv:
            key = kv.group(1)
            val = kv.group(2).strip()
            data[key] = val if val else []
    return data, body

written = []
for fname in sorted(os.listdir(src_dir)):
    if not fname.endswith(".md") or fname == "README.md":
        continue
    text = open(os.path.join(src_dir, fname), encoding="utf-8").read()
    data, body = parse_frontmatter(text)
    if data is None or "name" not in data:
        continue
    role = data["name"] if isinstance(data["name"], str) else fname[:-3]

    lines = ["---"]
    desc = data.get("description", "")
    if isinstance(desc, str) and desc:
        lines.append("description: " + json.dumps(desc))
    lines.append("mode: subagent")
    lines.append("hidden: true")  # cycle-internal: dispatched via the task tool

    tool_lines = []
    allow = data.get("tools")
    deny = data.get("disallowedTools")
    if isinstance(allow, list) and allow:
        allowed = {TOOL_MAP[t] for t in allow if t in TOOL_MAP}
        for t in BUILTINS:
            if t not in allowed:
                tool_lines.append(f"  {t}: false")
    elif isinstance(deny, list) and deny:
        for t in sorted({TOOL_MAP[t] for t in deny if t in TOOL_MAP}):
            tool_lines.append(f"  {t}: false")
    if tool_lines:
        lines.append("tools:")
        lines.extend(tool_lines)
    lines.append("---")

    header = (
        "<!-- GENERATED by loop-spec's lib/opencode-install.sh from "
        f"agents/{fname} — edit the source, not this file. Claude Code "
        f"model alias was `{data.get('model', '')}`; this agent inherits "
        "the session model (set `model: provider/model` here to pin). -->"
    )
    out_name = f"loop-spec-{role}.md"
    with open(os.path.join(out_dir, out_name), "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n" + header + "\n\n" + body.lstrip())
    written.append(os.path.join(out_dir, out_name))

print("\n".join(written))
PYEOF
)" || _die2 "agent conversion failed"
  while IFS= read -r p; do
    [[ -n "$p" ]] && CREATED+=("$p")
  done <<< "$agents_out"

  # 5. Manifest — versioned so future installs can tell their files apart.
  local version
  version="$(jq -r '.version' "$REPO_ROOT/package.json")"
  printf '%s\n' "${CREATED[@]}" | jq -R . | jq -s \
    --arg v "$version" --arg m "$([[ "$COPY" == "1" ]] && echo copy || echo link)" \
    '{version: $v, mode: $m, created: .}' > "$MANIFEST"

  echo "installed loop-spec $version -> $TARGET (${#CREATED[@]} paths, mode: $([[ "$COPY" == "1" ]] && echo copy || echo link))"
  [[ "$SKIPPED" == "0" ]] || { echo "some paths were skipped (see above)" >&2; return 1; }
}

case "$cmd" in
  install) install_cmd ;;
  uninstall) uninstall_cmd ;;
  status) status_cmd ;;
esac
