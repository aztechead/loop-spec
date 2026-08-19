#!/usr/bin/env bash
# codex-install.sh — install loop-spec into a Codex (https://developers.openai.com/codex)
# config tree through Codex's native discovery surfaces:
#
#   skills    -> <skills-root>/loop-spec-<name>/SKILL.md  (GENERATED adapter;
#                namespacing avoids shadowing user skills. Adapters embed the
#                Codex contract then the source SKILL.md. Discovery roots are
#                `$REPO/.agents/skills` for --project and `$HOME/.agents/skills`
#                for a user install — the locations Codex documents.)
#   agents    -> <codex-home>/agents/loop-spec-<role>.toml  (GENERATED: Codex
#                custom agents are TOML, not Claude Code markdown. Plugins do
#                not bundle agents, so this is the only way spawn_agent can
#                select a loop-spec role.)
#   hooks     -> <codex-home>/hooks.json  (merged SessionStart/UserPromptSubmit/
#                PreToolUse entries pointing at this checkout's Codex hooks)
#   env       -> <codex-home>/config.toml  marked [shell_environment_policy.set]
#                block so Bash subprocesses receive LOOP_SPEC_HARNESS without
#                waiting on hook trust
#   marketplace -> <project>/.agents/plugins/marketplace.json when --project
#                points at this clone (Codex resolves source.path relative to
#                the repo root). A user install prints the `codex plugin
#                marketplace add` command instead of writing outside HOME.
#
# A manifest records each artifact so reinstall/uninstall never removes
# user-replaced content.
#
# Usage:
#   codex-install.sh install   [--project <dir>]
#       [--model <role|adversarial>=<slug>]...
#   codex-install.sh uninstall [--project <dir>]
#   codex-install.sh status    [--project <dir>]
#
# Target resolution:
#   --project <dir>  -> <dir>/.codex  (per-project install)
#   CODEX_HOME       -> $CODEX_HOME   (override, used by tests)
#   default          -> ${CODEX_HOME:-~/.codex}
#
# Exit codes: 0 ok; 1 partial failure (a collision was skipped); 2 bad usage.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
bash "$SCRIPT_DIR/runtime-preflight.sh" check-jq || exit 2

_die2() { echo "codex-install.sh: $*" >&2; exit 2; }

cmd="${1:-}"
case "$cmd" in install|uninstall|status) ;; *) _die2 "unknown subcommand '${cmd:-}' (install|uninstall|status)" ;; esac
shift

PROJECT=""
MODEL_ROUTES_JSON="{}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="${2:-}"; [[ -n "$PROJECT" ]] || _die2 "--project needs a directory"; shift 2 ;;
    --model)
      [[ "$cmd" == "install" ]] || _die2 "--model is valid only with install"
      route="${2:-}"
      [[ -n "$route" && "$route" == *=* ]] || _die2 "--model needs role=slug"
      role="${route%%=*}"
      model="${route#*=}"
      [[ "$role" =~ ^[a-z0-9-]+$ ]] || _die2 "invalid model role '$role'"
      [[ -n "$model" && "$model" != *$'\n'* && "$model" != *$'\t'* ]] \
        || _die2 "model slug for '$role' is empty or contains whitespace"
      if [[ "$role" != "adversarial" && "$role" != "readonly" ]]; then
        grep -q "^name: ${role}$" "$REPO_ROOT"/agents/*.md 2>/dev/null \
          || _die2 "unknown loop-spec agent role '$role'"
      fi
      MODEL_ROUTES_JSON="$(jq -c --arg role "$role" --arg model "$model" \
        '.[$role] = $model' <<<"$MODEL_ROUTES_JSON")"
      shift 2
      ;;
    *) _die2 "unknown flag '$1'" ;;
  esac
done

if [[ -n "$PROJECT" ]]; then
  [[ -d "$PROJECT" ]] || _die2 "--project dir does not exist: $PROJECT"
  PROJECT="$(cd "$PROJECT" && pwd)"
  CODEX_DIR="$PROJECT/.codex"
  SKILLS_DIR="$PROJECT/.agents/skills"
  MARKET="$PROJECT/.agents/plugins/marketplace.json"
  WRITE_MARKET=0
  [[ "$PROJECT" == "$REPO_ROOT" ]] && WRITE_MARKET=1
else
  CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
  SKILLS_DIR="${HOME}/.agents/skills"
  MARKET="${HOME}/.agents/plugins/marketplace.json"
  WRITE_MARKET=0
fi
CODEX_DIR="$(python3 -c 'import os,sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' "$CODEX_DIR")"
AGENTS_DIR="$CODEX_DIR/agents"
CONFIG="$CODEX_DIR/config.toml"
HOOKS="$CODEX_DIR/hooks.json"
MANIFEST="$CODEX_DIR/loop-spec-install.json"

manifest_valid() {
  [[ -f "$MANIFEST" && ! -L "$MANIFEST" ]] || return 1
  jq -e '
    type == "object" and
    (.created | type == "array" and all(.[]; type == "string")) and
    ((has("artifacts") | not) or
      (.artifacts | type == "array" and all(.[];
        type == "object" and (.path | type == "string") and
        (.kind == "file" or .kind == "symlink"))))
  ' "$MANIFEST" >/dev/null 2>&1
}

path_is_safe() {
  python3 - "$CODEX_DIR" "$SKILLS_DIR" "$MARKET" "$1" <<'PYEOF'
import os, sys
codex, skills, market, candidate = map(os.path.abspath, sys.argv[1:])
roots = [codex, os.path.dirname(skills), os.path.dirname(os.path.dirname(market))]
try:
    ok = any(os.path.commonpath([root, candidate]) == root for root in roots if root)
except ValueError:
    ok = False
sys.exit(0 if ok and candidate not in (codex, skills) else 1)
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
if kind == "file":
    if not os.path.isfile(candidate) or os.path.islink(candidate):
        ok = False
    else:
        with open(candidate, "rb") as f:
            ok = hashlib.sha256(f.read()).hexdigest() == entry.get("sha256")
else:
    ok = False
sys.exit(0 if ok else 1)
PYEOF
    return
  fi
  if [[ -f "$candidate" ]] && grep -q "GENERATED by loop-spec's lib/codex-install.sh" "$candidate" 2>/dev/null; then
    return 0
  fi
  return 1
}

status_cmd() {
  if [[ ! -e "$MANIFEST" && ! -L "$MANIFEST" ]]; then
    echo "not installed: $CODEX_DIR (no loop-spec-install.json)"
    return 0
  fi
  manifest_paths_safe || { echo "invalid install manifest: $MANIFEST" >&2; return 1; }
  local degraded=0 p
  echo "installed: $CODEX_DIR"
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
  [[ -e "$MANIFEST" || -L "$MANIFEST" ]] || { echo "nothing to uninstall at $CODEX_DIR"; return 0; }
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
  python3 - "$CONFIG" <<'PY'
import os, re, sys
path = sys.argv[1]
if not os.path.isfile(path):
    raise SystemExit(0)
text = open(path, encoding="utf-8").read()
new = re.sub(r"\n?# BEGIN loop-spec\n.*?# END loop-spec\n?", "\n", text, flags=re.S)
if new != text:
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(new)
PY
  if [[ "$failed" == "0" ]]; then
    rm -f "$MANIFEST"
    echo "uninstalled loop-spec from $CODEX_DIR"
    return 0
  fi
  echo "uninstall incomplete; manifest retained at $MANIFEST" >&2
  return 1
}

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
  mkdir -p "$CODEX_DIR" "$AGENTS_DIR" "$SKILLS_DIR"
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
  generated_root="$(mktemp -d "${TMPDIR:-/tmp}/loop-spec-codex-install-XXXXXX")"
  trap "rm -rf '$generated_root'" EXIT

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
        return value.strip('"')
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
    adaptation = open(os.path.join(src_root, "shared", "codex-harness.md"), encoding="utf-8").read()
    body = [
        "---",
        f"name: {adapter_name}",
        "description: " + json.dumps(description),
        "allow_implicit_invocation: false",
        "---",
        "<!-- GENERATED by loop-spec's lib/codex-install.sh; edit the source, not this file. -->",
        "",
        "Before any bundled script, export the skill directory of the SOURCE skill",
        "(not this adapter) so `${CLAUDE_SKILL_DIR}/../../lib/...` resolves:",
        "",
        "```bash",
        ': "${CLAUDE_SKILL_DIR:=<this checkout>/skills/' + source_name + '}"',
        "[ -f \"${CLAUDE_SKILL_DIR}/../../lib/harness.sh\" ] || {",
        "  echo \"loop-spec: CLAUDE_SKILL_DIR does not resolve lib/; re-run bash lib/codex-install.sh install\" >&2",
        "  exit 2",
        "}",
        "```",
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
  python3 - "$skills_dir" "$REPO_ROOT" <<'PY'
import os, sys
skills_dir, repo = sys.argv[1:]
needle = "<this checkout>"
for root, _, files in os.walk(skills_dir):
    for name in files:
        path = os.path.join(root, name)
        text = open(path, encoding="utf-8").read().replace(needle, repo)
        open(path, "w", encoding="utf-8").write(text)
PY
  local d name
  for d in "$skills_dir"/*/; do
    name="$(basename "$d")"
    place_generated "$d/SKILL.md" "$SKILLS_DIR/$name/SKILL.md" || true
  done

  local agents_dir="$generated_root/agents"
  mkdir -p "$agents_dir"
  python3 - "$REPO_ROOT/agents" "$agents_dir" "$MODEL_ROUTES_JSON" <<'PYEOF' || _die2 "agent conversion failed"
import json, os, re, sys

src_dir, out_dir, routes_json = sys.argv[1:]
routes = json.loads(routes_json)
adversarial_roles = {
    "challenger", "iterate-judge", "code-reviewer", "security-reviewer",
}

def parse_frontmatter(text):
    m = re.match(r"^---\n(.*?)\n---\n(.*)$", text, re.S)
    if not m:
        return {}, text
    fm, body = m.group(1), m.group(2)
    data, key = {}, None
    for line in fm.splitlines():
        kv = re.match(r"^([A-Za-z][A-Za-z0-9_-]*):\s*(.*)$", line)
        if kv:
            key = kv.group(1)
            val = kv.group(2).strip().strip('"')
            data[key] = val
    return data, body

def toml_basic(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'

def toml_multiline(s):
    return '"""\n' + s.replace('"""', "'''") + '\n"""'

for name in sorted(os.listdir(src_dir)):
    if not name.endswith(".md") or name == "README.md":
        continue
    text = open(os.path.join(src_dir, name), encoding="utf-8").read()
    data, body = parse_frontmatter(text)
    role = data.get("name") or name[:-3]
    desc = data.get("description") or f"loop-spec {role} role"
    agent_name = "loop-spec-" + role
    model = routes.get(role) or (routes.get("adversarial") if role in adversarial_roles else "")
    lines = [
        "# GENERATED by loop-spec's lib/codex-install.sh; edit agents/" + name + ", not this file.",
        "name = " + toml_basic(agent_name),
        "description = " + toml_basic(desc),
        "developer_instructions = " + toml_multiline(body.strip()),
    ]
    if model:
        lines.append("model = " + toml_basic(model))
    with open(os.path.join(out_dir, agent_name + ".toml"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")

readonly_model = routes.get("readonly") or ""
readonly_body = (
    "You are a read-only loop-spec judge or spec compiler. Do not edit files, "
    "do not apply patches, and do not run mutating shell commands. Read the "
    "prompt, inspect the tree with read-only tools, and return the requested "
    "result."
)
readonly_lines = [
    "# GENERATED by loop-spec's lib/codex-install.sh; edit the installer, not this file.",
    'name = "loop-spec-readonly"',
    'description = "Read-only loop-spec judge and spec compiler. No edits."',
    "sandbox_mode = " + toml_basic("read-only"),
    "developer_instructions = " + toml_multiline(readonly_body),
]
if readonly_model:
    readonly_lines.append("model = " + toml_basic(readonly_model))
with open(os.path.join(out_dir, "loop-spec-readonly.toml"), "w", encoding="utf-8") as f:
    f.write("\n".join(readonly_lines) + "\n")
PYEOF
  for p in "$agents_dir"/*.toml; do
    place_generated "$p" "$AGENTS_DIR/$(basename "$p")" || true
  done

  python3 - "$CONFIG" "$REPO_ROOT" "$PROJECT" <<'PY' || _die2 "config.toml merge failed"
import os, re, sys
path, repo, project = sys.argv[1:]
begin, end = "# BEGIN loop-spec", "# END loop-spec"
skill_dir = os.path.join(repo, "skills", "cycle")
lines = [
    begin,
    "[shell_environment_policy.set]",
    'LOOP_SPEC_HARNESS = "codex"',
    'CLAUDE_PLUGIN_ROOT = "%s"' % repo.replace("\\", "\\\\").replace('"', '\\"'),
    'CLAUDE_SKILL_DIR = "%s"' % skill_dir.replace("\\", "\\\\").replace('"', '\\"'),
]
if project:
    lines.append('CLAUDE_PROJECT_DIR = "%s"' % project.replace("\\", "\\\\").replace('"', '\\"'))
lines.append(end)
block = "\n".join(lines) + "\n"
os.makedirs(os.path.dirname(path), exist_ok=True)
text = open(path, encoding="utf-8").read() if os.path.isfile(path) else ""
if begin in text and end in text:
    text = re.sub(re.escape(begin) + r".*?" + re.escape(end) + r"\n?", block, text, flags=re.S)
else:
    if text and not text.endswith("\n"):
        text += "\n"
    text += ("\n" if text else "") + block
with open(path, "w", encoding="utf-8") as fh:
    fh.write(text)
PY
  CREATED+=("$CONFIG")

  python3 - "$HOOKS" "$REPO_ROOT" <<'PY' || _die2 "hooks.json merge failed"
import json, os, sys
path, repo = sys.argv[1:]
marker = "loop-spec session start"
session = os.path.join(repo, "hooks", "codex-session-start.sh")
prompt = os.path.join(repo, "hooks", "codex-user-prompt.sh")
env = os.path.join(repo, "hooks", "codex-shell-env.sh")
owned = {
    "SessionStart": [{
        "matcher": "startup|resume|clear|compact",
        "hooks": [{"type": "command", "command": 'bash "%s"' % session,
                   "statusMessage": marker}],
    }],
    "UserPromptSubmit": [{
        "hooks": [{"type": "command", "command": 'bash "%s"' % prompt,
                   "statusMessage": "loop-spec done-criteria"}],
    }],
    "PreToolUse": [{
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": 'bash "%s"' % env,
                   "statusMessage": "loop-spec shell env"}],
    }],
}
data = {"hooks": {}}
if os.path.isfile(path):
    try:
        data = json.load(open(path, encoding="utf-8"))
    except Exception:
        data = {"hooks": {}}
hooks = data.setdefault("hooks", {})
for event, groups in owned.items():
    existing = hooks.get(event) or []
    kept = []
    for group in existing:
        messages = [h.get("statusMessage") for h in (group.get("hooks") or [])]
        if any(isinstance(m, str) and m.startswith("loop-spec ") for m in messages):
            continue
        kept.append(group)
    hooks[event] = groups + kept
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
  CREATED+=("$HOOKS")

  if [[ "$WRITE_MARKET" == "1" ]]; then
    mkdir -p "$(dirname "$MARKET")"
    cat > "$generated_root/marketplace.json" <<EOF
{
  "name": "loop-spec-local",
  "interface": {
    "displayName": "loop-spec"
  },
  "plugins": [
    {
      "name": "loop-spec",
      "source": {
        "source": "local",
        "path": "./"
      },
      "policy": {
        "installation": "AVAILABLE",
        "authentication": "ON_INSTALL"
      },
      "category": "Productivity"
    }
  ]
}
EOF
    place_generated "$generated_root/marketplace.json" "$MARKET" || true
  fi

  local version
  version="$(jq -r '.version' "$REPO_ROOT/.codex-plugin/plugin.json")"
  python3 - "$MANIFEST" "$version" "${PROJECT:-user}" "$REPO_ROOT" "${CREATED[@]}" <<'PY'
import hashlib, json, os, sys
manifest, version, mode, repo = sys.argv[1:5]
created = sys.argv[5:]
artifacts = []
for path in created:
    entry = {"path": path, "kind": "file"}
    if os.path.isfile(path) and not os.path.islink(path):
        with open(path, "rb") as f:
            entry["sha256"] = hashlib.sha256(f.read()).hexdigest()
    artifacts.append(entry)
payload = {
    "version": version,
    "mode": mode,
    "repo": repo,
    "created": created,
    "artifacts": artifacts,
}
os.makedirs(os.path.dirname(manifest), exist_ok=True)
with open(manifest, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, indent=2)
    fh.write("\n")
PY

  if [[ ${#old_paths[@]} -gt 0 ]]; then
    local old
    for old in "${old_paths[@]}"; do
      manifest_contains "$old" && continue
      [[ -e "$old" || -L "$old" ]] || continue
      if python3 - "$MANIFEST" "$old" <<'PY'; then
import hashlib, json, os, sys
# previous identity is gone; only delete leftover generated files we still recognize
path = sys.argv[2]
sys.exit(0 if os.path.isfile(path) and b"GENERATED by loop-spec" in open(path, "rb").read()[:400] else 1)
PY
        rm -rf "$old" || true
      fi
    done
  fi

  echo "installed loop-spec for Codex at $CODEX_DIR"
  echo "  skills: $SKILLS_DIR"
  echo "  agents: $AGENTS_DIR"
  echo "Next: trust the loop-spec hooks with /hooks, then invoke \$loop-spec-auto"
  echo "      or: LOOP_SPEC_NON_INTERACTIVE=1 codex exec --json --sandbox workspace-write \\"
  echo "          \"Load the loop-spec-auto skill and run: <description>\""
  if [[ "$WRITE_MARKET" != "1" ]]; then
    echo "Plugin install (skills + bundled hooks from the clone):"
    echo "  codex plugin marketplace add https://github.com/aztechead/loop-spec.git"
    echo "  codex plugin add loop-spec"
  fi
  [[ "$SKIPPED" == "0" ]]
}

case "$cmd" in
  install) install_cmd ;;
  uninstall) uninstall_cmd ;;
  status) status_cmd ;;
esac
