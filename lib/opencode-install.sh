#!/usr/bin/env bash
# opencode-install.sh — install loop-spec into an opencode (https://opencode.ai)
# config directory, entirely through opencode's NATIVE discovery surfaces:
#
#   skills    -> <config>/skills/loop-spec-<name>/SKILL.md  (GENERATED adapter;
#                namespacing avoids shadowing user skills, then the adapter
#                reads this checkout's source SKILL.md and OpenCode contract)
#   command   -> <config>/commands/loop-debug.md   ({command,commands}/**/*.md;
#                $ARGUMENTS substitution works in both harnesses)
#   wrappers  -> <config>/commands/loop-spec/<name>.md  (GENERATED: one command
#                per skill, loading as /loop-spec/<name>. opencode maps skills
#                to commands server-side, but the TUI hides source=="skill"
#                entries from the "/" autocomplete popup — without real command
#                files the skills are undiscoverable. Namespaced under
#                loop-spec/ so they can never shadow opencode's built-in
#                palette slashes (/debug, /status, /skills) or user commands.)
#   plugin    -> <config>/plugins/loop-spec.ts     ({plugin,plugins}/*.{ts,js};
#                the bridge in extensions/opencode/loop-spec.ts — realpaths
#                itself, so a symlink here still finds the package root)
#   agents    -> <config>/agents/loop-spec-<role>.md  (GENERATED: opencode's
#                agent frontmatter differs from Claude Code's, so agents/*.md
#                are converted — description kept, mode: subagent, CC tool
#                allow/deny lists mapped to opencode permissions. Claude Code
#                model aliases (sonnet/opus) mean nothing to opencode, so
#                agents inherit the session model; pin per-agent models by
#                editing the generated file with a provider/model id.)
#
# Source artifacts are symlinked (one clone, updates flow through `git pull`);
# generated wrappers and agents are files. A manifest records each artifact's
# identity so reinstall/uninstall never removes user-replaced content.
#
# Usage:
#   opencode-install.sh install   [--project <dir>]
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
[[ "$COPY" == "0" ]] || _die2 "--copy is not supported: OpenCode skills require the package's shared lib/hooks tree; use the default symlink install"

if [[ -n "$PROJECT" ]]; then
  [[ -d "$PROJECT" ]] || _die2 "--project dir does not exist: $PROJECT"
  TARGET="$(cd "$PROJECT" && pwd)/.opencode"
else
  TARGET="${OPENCODE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode}"
fi
# Normalize lexical `..` before any manifest boundary checks.
TARGET="$(python3 -c 'import os,sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' "$TARGET")"
MANIFEST="$TARGET/loop-spec-install.json"

# ---------------------------------------------------------------------------
manifest_valid() {
  [[ -f "$MANIFEST" && ! -L "$MANIFEST" ]] || return 1
  jq -e '
    type == "object" and
    (.created | type == "array" and all(.[]; type == "string")) and
    ((has("artifacts") | not) or
      (.artifacts | type == "array" and all(.[];
        type == "object" and (.path | type == "string") and
        (.kind == "symlink" or .kind == "file" or .kind == "directory"))))
  ' "$MANIFEST" >/dev/null 2>&1
}

path_is_safe() {
  python3 - "$TARGET" "$1" <<'PYEOF'
import os, sys
target, candidate = map(os.path.abspath, sys.argv[1:])
try:
    lexical_ok = os.path.commonpath([target, candidate]) == target and candidate != target
    parent_ok = os.path.commonpath([os.path.realpath(target), os.path.realpath(os.path.dirname(candidate))]) == os.path.realpath(target)
except ValueError:
    lexical_ok = parent_ok = False
sys.exit(0 if lexical_ok and parent_ok else 1)
PYEOF
}

manifest_paths_safe() {
  manifest_valid || return 1
  local p
  while IFS= read -r p; do
    path_is_safe "$p" || return 1
  done < <(jq -r '.created[]' "$MANIFEST")
}

manifest_contains() {
  [[ -f "$MANIFEST" && ! -L "$MANIFEST" ]] || return 1
  jq -e --arg p "$1" '.created | index($p)' "$MANIFEST" >/dev/null 2>&1
}

artifact_matches() {
  local candidate="$1"
  [[ -e "$candidate" || -L "$candidate" ]] || return 1
  if [[ -f "$MANIFEST" && ! -L "$MANIFEST" ]] && jq -e '.artifacts | type == "array"' "$MANIFEST" >/dev/null 2>&1; then
    python3 - "$MANIFEST" "$candidate" <<'PYEOF'
import hashlib, json, os, sys
manifest, candidate = sys.argv[1:]
with open(manifest, encoding="utf-8") as f:
    entries = json.load(f).get("artifacts", [])
entry = next((item for item in entries if item.get("path") == candidate), None)
if not entry:
    sys.exit(1)
kind = entry.get("kind")
if kind == "symlink":
    ok = os.path.islink(candidate) and os.readlink(candidate) == entry.get("target")
elif kind == "file":
    if not os.path.isfile(candidate) or os.path.islink(candidate):
        ok = False
    else:
        with open(candidate, "rb") as f:
            ok = hashlib.sha256(f.read()).hexdigest() == entry.get("sha256")
else:
    ok = False  # Never recursively delete an unverified real directory.
sys.exit(0 if ok else 1)
PYEOF
    return
  fi

  # Legacy manifests had no identities. Only recognize unmodified symlinks
  # into this checkout or generated files carrying loop-spec's marker.
  if [[ -L "$candidate" ]]; then
    case "$(readlink "$candidate")" in "$REPO_ROOT"/*) return 0 ;; esac
  elif [[ -f "$candidate" ]] && grep -q "GENERATED by loop-spec's lib/opencode-install.sh" "$candidate"; then
    return 0
  fi
  return 1
}

status_cmd() {
  if [[ ! -e "$MANIFEST" && ! -L "$MANIFEST" ]]; then
    echo "not installed: $TARGET (no loop-spec-install.json)"
    return 0
  fi
  manifest_paths_safe || { echo "invalid install manifest: $MANIFEST" >&2; return 1; }
  local degraded=0 p
  echo "installed: $TARGET"
  jq -r '"version: \(.version)\nmode: \(.mode)\npaths:", (.created[] | "  \(.)")' "$MANIFEST"
  while IFS= read -r p; do
    if [[ ! -e "$p" && ! -L "$p" ]]; then
      echo "missing: $p" >&2
      degraded=1
    elif ! artifact_matches "$p"; then
      echo "modified: $p" >&2
      degraded=1
    fi
  done < <(jq -r '.created[]' "$MANIFEST")
  [[ "$degraded" == "0" ]]
}

uninstall_cmd() {
  [[ -e "$MANIFEST" || -L "$MANIFEST" ]] || { echo "nothing to uninstall at $TARGET"; return 0; }
  manifest_paths_safe || { echo "refusing unsafe or invalid manifest: $MANIFEST" >&2; return 1; }
  local failed=0 p
  while IFS= read -r p; do
    [[ -e "$p" || -L "$p" ]] || continue
    if artifact_matches "$p"; then
      rm -rf "$p" || { echo "could not remove: $p" >&2; failed=1; }
    else
      echo "preserve (modified or replaced): $p" >&2
      failed=1
    fi
  done < <(jq -r '.created[]' "$MANIFEST")
  if [[ "$failed" == "0" ]]; then
    rm -f "$MANIFEST"
    echo "uninstalled loop-spec from $TARGET"
    return 0
  fi
  echo "uninstall incomplete; manifest retained at $MANIFEST" >&2
  return 1
}

# place <src> <dst>: symlink (default) or copy; refuses to clobber anything
# that is not already a link/copy owned by a previous loop-spec install.
SKIPPED=0
CREATED=()
prepare_destination() {
  local dst="$1"
  if [[ ! -e "$dst" && ! -L "$dst" ]]; then return 0; fi
  if manifest_contains "$dst" && path_is_safe "$dst" && artifact_matches "$dst"; then
    rm -rf "$dst" || { echo "could not replace: $dst" >&2; SKIPPED=1; return 1; }
    return 0
  fi
  echo "skip (exists, not an unmodified loop-spec artifact): $dst" >&2
  SKIPPED=1
  return 1
}

place() {
  local src="$1" dst="$2"
  prepare_destination "$dst" || return 1
  mkdir -p "$(dirname "$dst")"
  ln -s "$src" "$dst" || { echo "could not link: $dst" >&2; SKIPPED=1; return 1; }
  CREATED+=("$dst")
}

place_generated() {
  local src="$1" dst="$2"
  prepare_destination "$dst" || return 1
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst" || { echo "could not write: $dst" >&2; SKIPPED=1; return 1; }
  CREATED+=("$dst")
}

install_cmd() {
  command -v python3 >/dev/null 2>&1 || _die2 "python3 is required (agent conversion)"
  command -v jq >/dev/null 2>&1 || _die2 "jq is required"
  mkdir -p "$TARGET"
  if [[ -L "$MANIFEST" ]]; then
    _die2 "refusing manifest symlink: $MANIFEST"
  fi
  local old_paths=() p
  if [[ -e "$MANIFEST" ]]; then
    manifest_paths_safe || _die2 "existing manifest is invalid or unsafe: $MANIFEST"
    while IFS= read -r p; do
      old_paths+=("$p")
    done < <(jq -r '.created[]' "$MANIFEST")
  fi
  local generated_root
  generated_root="$(mktemp -d "${TMPDIR:-/tmp}/loop-spec-opencode-install-XXXXXX")"
  trap "rm -rf '$generated_root'" EXIT

  # 1. Namespaced skill adapters. OpenCode keys skills globally by frontmatter
  #    name, so installing generic names like cycle/plan/status would shadow
  #    user or project skills. Each adapter loads the OpenCode contract, then
  #    reads the source SKILL.md; that read also lets the plugin set the real
  #    CLAUDE_SKILL_DIR before any bundled script runs.
  local skills_dir="$generated_root/skills"
  mkdir -p "$skills_dir"
  python3 - "$REPO_ROOT/skills" "$skills_dir" <<'PYEOF' || _die2 "skill adapter generation failed"
import json, os, re, sys
src_root, out_root = sys.argv[1:]

def field(text, key, default=""):
    match = re.search(rf"^{re.escape(key)}:\s*(.*)$", text, re.M)
    if not match:
        return default
    value = match.group(1).strip()
    if value not in (">", ">-", "|", "|-"):
        return value.strip(chr(34))
    lines = text[match.end():].splitlines()
    parts = []
    for line in lines:
        if line.startswith("  ") or not line.strip():
            if line.strip():
                parts.append(line.strip())
        else:
            break
    return " ".join(parts)

for directory in sorted(os.listdir(src_root)):
    source = os.path.join(src_root, directory, "SKILL.md")
    if not os.path.isfile(source):
        continue
    text = open(source, encoding="utf-8").read()
    source_name = field(text, "name", directory)
    description = field(text, "description", f"Run the loop-spec {source_name} workflow.")
    adapter_name = "loop-spec-" + source_name
    output_dir = os.path.join(out_root, adapter_name)
    os.makedirs(output_dir)
    source_body = re.sub(r"^---\n.*?\n---\n", "", text, count=1, flags=re.S)
    adaptation = open(os.path.join(src_root, "shared", "opencode-harness.md"), encoding="utf-8").read()
    body = [
        "---",
        f"name: {adapter_name}",
        "description: " + json.dumps(description),
        "---",
        "<!-- GENERATED by loop-spec's lib/opencode-install.sh; edit the source, not this file. -->",
        "",
        adaptation.rstrip(),
        "",
        "# Source Skill",
        "",
        source_body.lstrip(),
    ]
    with open(os.path.join(output_dir, "SKILL.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(body))
PYEOF
  local d name p
  for d in "$skills_dir"/*/; do
    name="$(basename "$d")"
    place_generated "$d/SKILL.md" "$TARGET/skills/$name/SKILL.md" || true
  done

  # 2. The one-shot command (loads as /loop-debug; $ARGUMENTS is shared syntax).
  place "$REPO_ROOT/commands/loop-debug.md" "$TARGET/commands/loop-debug.md" || true

  # 2b. Skill command wrappers — GENERATED, never linked (derived content).
  #     opencode's TUI hides skill-sourced slash entries from the "/" popup
  #     (packages/tui autocomplete: `if (source === "skill") continue`), so a
  #     real command per skill is the only way users can discover and invoke
  #     them as /loop-spec/<name>. Real commands also take precedence over the
  #     server's skill->command mapping only when names collide — these are
#     namespaced, matching the generated loop-spec-<name> skill adapters.
  local wrappers_dir="$generated_root/wrappers"
  mkdir -p "$wrappers_dir"
  python3 - "$REPO_ROOT/skills" "$wrappers_dir" <<'PYEOF' || _die2 "skill command wrapper generation failed"
import json, os, re, sys

src_root, out_dir = sys.argv[1], sys.argv[2]

def frontmatter(text):
    m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    return m.group(1) if m else ""

def parse(fm):
    # Line-based parse of the simple frontmatter loop-spec skills use:
    # `key: value` plus YAML folded/literal block scalars (the loop-runner
    # description is `>-`), whose indented continuation lines are joined.
    data = {}
    lines = fm.splitlines()
    i = 0
    while i < len(lines):
        kv = re.match(r"^([A-Za-z][A-Za-z0-9_-]*):\s*(.*)$", lines[i])
        if kv:
            key, val = kv.group(1), kv.group(2).strip()
            if val in (">", ">-", "|", "|-"):
                parts = []
                i += 1
                while i < len(lines) and (lines[i].startswith("  ") or not lines[i].strip()):
                    parts.append(lines[i].strip())
                    i += 1
                data[key] = " ".join(p for p in parts if p)
                continue
            data[key] = val
        i += 1
    return data

written = []
for name in sorted(os.listdir(src_root)):
    skill_md = os.path.join(src_root, name, "SKILL.md")
    if not os.path.isfile(skill_md):
        continue
    data = parse(frontmatter(open(skill_md, encoding="utf-8").read()))
    skill = data.get("name") or name
    adapter = "loop-spec-" + skill
    desc = data.get("description", "")
    hint = data.get("argument-hint", "").strip().strip(chr(34))
    body = [
        "---",
        "description: " + json.dumps(desc),
        "---",
        "<!-- GENERATED by loop-spec's lib/opencode-install.sh from "
        f"skills/{name}/SKILL.md — edit the source, not this file. -->",
        "",
        f"Load the namespaced loop-spec adapter with the native skill tool — call "
        f"skill({{ name: \"{adapter}\" }}). That adapter reads "
        "opencode-harness.md and the source skill, then applies the OpenCode "
        "tool, question, dispatch, and model substitutions before execution.",
        "",
    ]
    if hint:
        body.append(f"Argument shape: {hint}")
        body.append("")
    body.append("Arguments: $ARGUMENTS")
    out = os.path.join(out_dir, f"{skill}.md")
    with open(out, "w", encoding="utf-8") as f:
        f.write("\n".join(body) + "\n")
    written.append(out)
PYEOF
  for p in "$wrappers_dir"/*.md; do
    place_generated "$p" "$TARGET/commands/loop-spec/$(basename "$p")" || true
  done

  # 3. The bridge plugin.
  place "$REPO_ROOT/extensions/opencode/loop-spec.ts" "$TARGET/plugins/loop-spec.ts" || true

  # 4. Agents — converted, never linked (frontmatter dialects differ).
  local agents_dir="$generated_root/agents"
  mkdir -p "$agents_dir"
  python3 - "$REPO_ROOT/agents" "$agents_dir" <<'PYEOF' || _die2 "agent conversion failed"
import json, os, re, sys

src_dir, out_dir = sys.argv[1], sys.argv[2]

# CC tool name -> opencode tool id (registry ids, packages/opencode/src/tool).
TOOL_MAP = {
    "Read": "read", "Write": "edit", "Edit": "edit", "NotebookEdit": "edit",
    "Bash": "bash", "Grep": "grep", "Glob": "glob",
    "WebFetch": "webfetch", "WebSearch": "websearch",
    "Skill": "skill", "Agent": "task", "Task": "task",
    "AskUserQuestion": "question",
    "TaskCreate": "todowrite", "TaskUpdate": "todowrite",
    "TaskList": "todowrite", "TaskGet": "todowrite",
}
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

    permission_lines = []
    allow = data.get("tools")
    deny = data.get("disallowedTools")
    if isinstance(allow, list) and allow:
        allowed = {TOOL_MAP[t] for t in allow if t in TOOL_MAP}
        permission_lines.append('  "*": deny')
        for tool_id in sorted(allowed):
            permission_lines.append(f"  {tool_id}: allow")
    elif isinstance(deny, list) and deny:
        for t in sorted({TOOL_MAP[t] for t in deny if t in TOOL_MAP}):
            permission_lines.append(f"  {t}: deny")
    if permission_lines:
        lines.append("permission:")
        lines.extend(permission_lines)
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

# A primary agent used by compiler/judge passes. The built-in plan agent still
# allows bash, so it is not a read-only boundary for headless execution.
readonly = os.path.join(out_dir, "loop-spec-readonly.md")
with open(readonly, "w", encoding="utf-8") as f:
    f.write("""---
description: Read-only loop-spec compiler and judge for headless OpenCode runs.
mode: primary
hidden: true
permission:
  "*": deny
  bash: deny
  edit: deny
  task: deny
  read: allow
  glob: allow
  grep: allow
---
<!-- GENERATED by loop-spec's lib/opencode-install.sh; edit the installer, not this file. -->

Analyze the requested files and return the requested result. Never modify files,
run shell commands, dispatch subagents, or request permissions.
""")
PYEOF
  for p in "$agents_dir"/*.md; do
    place_generated "$p" "$TARGET/agents/$(basename "$p")" || true
  done

  # Remove artifacts owned by the previous manifest but no longer produced by
  # this layout (notably pre-namespacing skills/<name> symlinks). Modified or
  # unverifiable legacy content is preserved and remains tracked for recovery.
  local old current still_created
  if [[ "${#old_paths[@]}" -gt 0 ]]; then
  for old in "${old_paths[@]}"; do
    still_created=0
    for current in "${CREATED[@]}"; do
      if [[ "$current" == "$old" ]]; then
        still_created=1
        break
      fi
    done
    [[ "$still_created" == "1" ]] && continue
    if [[ ! -e "$old" && ! -L "$old" ]]; then
      continue
    elif artifact_matches "$old"; then
      rm -rf "$old" || { echo "could not remove legacy artifact: $old" >&2; CREATED+=("$old"); SKIPPED=1; }
    else
      echo "preserve legacy artifact (modified or unverifiable): $old" >&2
      CREATED+=("$old")
      SKIPPED=1
    fi
  done
  fi

  # 5. Manifest — versioned so future installs can tell their files apart.
  local version manifest_tmp
  version="$(jq -r '.version' "$REPO_ROOT/package.json")"
  manifest_tmp="$generated_root/loop-spec-install.json"
  python3 - "$version" "$manifest_tmp" "${CREATED[@]}" <<'PYEOF' || _die2 "manifest generation failed"
import hashlib, json, os, sys
version, output, *paths = sys.argv[1:]
artifacts = []
for path in paths:
    if os.path.islink(path):
        artifacts.append({"path": path, "kind": "symlink", "target": os.readlink(path)})
    elif os.path.isfile(path):
        with open(path, "rb") as f:
            digest = hashlib.sha256(f.read()).hexdigest()
        artifacts.append({"path": path, "kind": "file", "sha256": digest})
    elif os.path.isdir(path):
        artifacts.append({"path": path, "kind": "directory"})
    else:
        raise SystemExit("missing generated artifact: " + path)
with open(output, "w", encoding="utf-8") as f:
    json.dump({
        "product": "loop-spec",
        "manifestVersion": 2,
        "version": version,
        "mode": "link",
        "created": paths,
        "artifacts": artifacts,
    }, f, indent=2)
    f.write("\n")
PYEOF
  mv "$manifest_tmp" "$MANIFEST" || _die2 "could not write manifest: $MANIFEST"

  rm -rf "$generated_root"
  trap - EXIT
  echo "installed loop-spec $version -> $TARGET (${#CREATED[@]} paths, mode: link)"
  [[ "$SKIPPED" == "0" ]] || { echo "some paths were skipped (see above)" >&2; return 1; }
}

case "$cmd" in
  install) install_cmd ;;
  uninstall) uninstall_cmd ;;
  status) status_cmd ;;
esac
