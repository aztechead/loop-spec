#!/usr/bin/env bash
# Codex harness coverage: the Codex adaptation is a web of cross-file
# couplings (harness probe -> capability gates -> spawn_agent/skill mapping ->
# installer -> loop-runner backend). A rename or dropped pointer on any edge
# silently strands Codex runs on a tool or path that does not exist there.
# This pins every edge, mirroring tests/opencode-harness-coverage.test.sh and
# tests/adk-harness-coverage.test.sh.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fixed-string-coverage.sh"

# file<TAB>fixed-string that must be present.
checks=(
  # -- the adaptation contract exists and names its collaborators
  "skills/shared/codex-harness.md	lib/harness.sh"
  "skills/shared/codex-harness.md	execute-loop-fleet.md"
  "skills/shared/codex-harness.md	autonomous-mode.md"
  "skills/shared/codex-harness.md	--agent-cli codex"
  "skills/shared/codex-harness.md	lib/codex-install.sh"
  "skills/shared/codex-harness.md	spawn_agent"
  "skills/shared/codex-harness.md	subagent_type"
  "skills/shared/codex-harness.md	agent_type"
  "skills/shared/codex-harness.md	loop-spec-<role>"
  "skills/shared/codex-harness.md	executionRootMode: \"in-place\""
  "skills/shared/codex-harness.md	lib/pr-delivery.sh"
  "skills/shared/codex-harness.md	directive-only"
  "skills/shared/codex-harness.md	does not pretend worktree creation changed cwd"
  "skills/shared/codex-harness.md	shell_environment_policy.set"
  "skills/shared/codex-harness.md	codex exec --json"
  "skills/shared/codex-harness.md	loop-spec-auto"
  "skills/shared/codex-harness.md	loop-spec-readonly"
  "skills/shared/codex-harness.md	token"
  "skills/shared/codex-harness.md	Graph engine (GDD)"
  "skills/shared/codex-harness.md	lib/graph/run.sh"
  "skills/shared/codex-harness.md	LOOP_SPEC_PHASE_MODEL_*"
  "skills/shared/codex-harness.md	request_user_input"
  "skills/shared/codex-harness.md	default_mode_request_user_input"
  "skills/shared/codex-harness.md	end the turn"
  # -- native plugin + marketplace
  ".codex-plugin/plugin.json	\"hooks\": \"./hooks/codex-hooks.json\""
  ".codex-plugin/plugin.json	\"skills\": \"./skills/\""
  ".codex-plugin/plugin.json	\$loop-spec-cycle"
  ".agents/plugins/marketplace.json	\"path\": \"./\""
  "hooks/codex-hooks.json	codex-session-start.sh"
  "hooks/codex-hooks.json	codex-shell-env.sh"
  "hooks/codex-session-start.sh	SESSION_START_SCRIPTS"
  "hooks/codex-session-start.sh	LOOP_SPEC_HARNESS=codex"
  "hooks/codex-session-start.sh	request_user_input"
  "hooks/codex-shell-env.sh	permissionDecision"
  "hooks/codex-shell-env.sh	updatedInput"
  # -- the harness probe knows codex and grants the subagent capability
  "lib/harness.sh	codex"
  "lib/harness.sh	claude|opencode|adk|codex"
  "lib/execute-rung.sh	harness.sh"
  # -- the session layer is one probe question, and every contract says how it answers there
  "lib/harness.sh	session-layer"
  "lib/execute-rung.sh	session-layer"
  "skills/shared/codex-harness.md	session-layer"
  "skills/shared/execute-rungs.md	session-layer"
  # -- capability gates are non-claude-gated
  "lib/teams-capability.sh	!= \"claude\""
  "lib/workflow-availability.sh	!= \"claude\""
  # -- dispatch docs route Codex through spawn_agent
  "skills/shared/dispatch.md	codex-harness.md"
  "skills/cycle/SKILL.md	codex-harness.md"
  "skills/shared/tier-matrix.md	codex-harness.md"
  "skills/shared/dispatch.md	Codex harness"
  "skills/shared/dispatch.md	codex-harness.md"
  "skills/shared/dispatch.md	request_user_input"
  "skills/shared/autonomous-mode.md	codex exec --json"
  "skills/shared/model-matrix.md	codex-harness.md"
  "commands/loop-debug.md	codex-harness.md"
  "docs/loop-spec/sentinel.md	codex exec --json"
  "lib/issue-intake.sh	exec --json"
  # -- installer places agents, adapters, and env
  "lib/codex-install.sh	loop-spec-install.json"
  "lib/codex-install.sh	loop-spec-readonly"
  "lib/codex-install.sh	shell_environment_policy.set"
  "lib/codex-install.sh	.agents/skills"
  "lib/codex-install.sh	s.replace(\"\\\\\", \"\\\\\\\\\").replace('\"\"\"', \"'''\")"
  "lib/codex-install.sh	default_mode_request_user_input"
  "lib/codex-install.sh	loop-spec-features"
  # -- loop-runner backend
  "skills/loop-runner/scripts/loop.py	def run_codex"
  "skills/loop-runner/scripts/loop.py	codex"
  "skills/loop-runner/scripts/supervisor.py	codex"
  "skills/loop-runner/scripts/compile_spec.py	codex"
  "skills/loop-runner/SKILL.md	--agent-cli codex"
  "skills/shared/execute-loop-fleet.md	--agent-cli codex"
  "skills/loop-runner/tests/fakecodex	thread.started"
  "skills/shared/graph-contract.md	codex-harness.md"
  "skills/shared/route-exit-contract.md	codex-harness.md"
  "lib/bump-version.sh	.codex-plugin/plugin.json"
  "lib/graph/run.sh	harness-neutral"
  "lib/graph/engine.py	harness-neutral"
)

check_fixed_strings "${checks[@]}"

probe() {
  got="$(LOOP_SPEC_HARNESS=codex bash lib/harness.sh "$3" 2>/dev/null)"
  if [[ "$got" == "$2" ]]; then
    PASS=$((PASS+1)); echo "PASS: harness.sh $3 under codex == '$2'"
  else
    FAIL=$((FAIL+1)); echo "FAIL: harness.sh $3 under codex == '$got', want '$2'"
  fi
}
probe "detect" "codex" detect
probe "cli" "codex" cli
probe "subagents" "true" subagents

for gate in "teams-capability.sh	none" "workflow-availability.sh	false"; do
  script="${gate%%	*}"; want="${gate#*	}"
  got="$(LOOP_SPEC_HARNESS=codex CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 \
         LOOP_SPEC_WORKFLOWS_AVAILABLE=1 LOOP_SPEC_TEAMS_MODE=implicit \
         bash "lib/$script" 2>/dev/null)"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS+1)); echo "PASS: lib/$script under codex == '$want' despite a positive override"
  else
    FAIL=$((FAIL+1)); echo "FAIL: lib/$script under codex == '$got', want '$want'"
  fi
done

CX_DOC="skills/shared/codex-harness.md"
if grep -qF 'export LOOP_SPEC_SKILL_DIR=' "$CX_DOC"; then
  PASS=$((PASS+1)); echo "PASS: $CX_DOC re-exports the active source skill directory"
else
  FAIL=$((FAIL+1)); echo "FAIL: $CX_DOC lost the per-skill source-directory re-export"
fi
if grep -qF 'Before EVERY bundled script' lib/codex-install.sh; then
  PASS=$((PASS+1)); echo "PASS: generated adapters re-export before every bundled command"
else
  FAIL=$((FAIL+1)); echo "FAIL: generated adapters do not scope LOOP_SPEC_SKILL_DIR per command"
fi

if jq -e '.hooks and .skills' .codex-plugin/plugin.json >/dev/null; then
  PASS=$((PASS+1)); echo "PASS: .codex-plugin/plugin.json names skills and hooks"
else
  FAIL=$((FAIL+1)); echo "FAIL: .codex-plugin/plugin.json missing skills or hooks"
fi

# Run the registered hooks from outside the payload cwd, as a plugin host can.
if python3 - <<'PY'
import json, os, pathlib, re, subprocess, tempfile
root = pathlib.Path.cwd()
config = json.loads((root / 'hooks/codex-hooks.json').read_text())['hooks']
env = dict(os.environ, PLUGIN_ROOT=str(root))
env.pop('CLAUDE_PROJECT_DIR', None)
with tempfile.TemporaryDirectory() as tmp:
    project = pathlib.Path(tmp) / 'project'
    project.mkdir()
    payload = dict(cwd=str(project), prompt='$loop-spec-cycle autonomous fix x')
    def run(event, active=False):
        results = []
        for group in config.get(event, []):
            if event == 'PreToolUse' and not re.fullmatch(group.get('matcher', '.*'), payload['tool_name']):
                continue
            for hook in group['hooks']:
                results.append(subprocess.run(
                    hook['command'], shell=True, env=env, cwd=tmp,
                    input=json.dumps(dict(payload, stop_hook_active=active)),
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    universal_newlines=True))
        return results
    assert all(p.returncode == 0 for p in run('UserPromptSubmit'))
    stamp = json.loads((project / '.loop-spec/invocation-stamp.json').read_text())
    assert stamp['skill'] == 'cycle' and stamp['args'] == 'autonomous fix x'
    assert any(p.returncode == 2 and 'never began' in p.stderr for p in run('Stop'))
    assert all(p.returncode == 0 for p in run('Stop', active=True))
    (project / '.loop-spec/invocation-stamp.json').unlink()
    assert all(p.returncode == 0 for p in run('Stop'))
    probe = pathlib.Path(tmp) / 'probe.sh'
    probe.write_text('echo "unaccounted ageSeconds=0 autonomous=true"\n')
    env['LOOP_SPEC_CYCLE_RESULT_BIN'] = str(probe)
    assert any(p.returncode == 2 and 'terminal result' in p.stderr for p in run('Stop'))
    for tool, args, expected in [
        ('Bash', {'command': 'codex exec nested'}, 2),
        ('apply_patch', {'command': '*** Begin Patch\n*** Add File: safe.txt\n+x\n*** Update File: .loop-spec/last-result.json\n@@\n-x\n+y\n*** End Patch'}, 2),
        ('apply_patch', {'command': '*** Begin Patch\n*** Update File: safe.txt\n*** Move to: .loop-spec/result.json\n@@\n-x\n+y\n*** End Patch'}, 2),
        ('apply_patch', {'command': '*** Begin Patch\n*** Add File: app.py\n+pass\n*** End Patch'}, 0),
    ]:
        payload.update(tool_name=tool, tool_input=args)
        results = run('PreToolUse')
        assert results, tool
        assert any(p.returncode == expected for p in results) if expected else all(p.returncode == 0 for p in results)
    subprocess.run(['git', 'init', '-q', str(project)], check=True)
    feature = project / '.loop-spec/features/guarded'
    feature.mkdir(parents=True)
    (feature / 'feature.json').write_text('{"slug":"guarded","schemaVersion":7}')
    docs = project / 'docs/loop-spec/features/guarded'
    docs.mkdir(parents=True)
    (docs / 'SPEC.md').write_text('---\nunresolved_questions: []\nfootprint:\n  - app.py\n---\n# guarded\n')
    for artifact in ('SPEC.md', 'VERIFICATION.md'):
        payload.update(tool_name='apply_patch', tool_input={'command':
            '*** Begin Patch\n*** Update File: docs/loop-spec/features/guarded/' + artifact + '\n@@\n-x\n+y\n*** End Patch'})
        assert any(p.returncode == 2 and 'driver writes' in p.stderr for p in run('PreToolUse')), artifact
PY
then
  PASS=$((PASS+1)); echo "PASS: registered Codex prompt and Stop hooks enforce driver state"
else
  FAIL=$((FAIL+1)); echo "FAIL: registered Codex prompt and Stop hooks lost enforcement"
fi

finish_fixed_string_coverage
