# CC Capability Probe Findings

**Date:** 2026-05-06
**Method:** Inspect existing CC plugin hook implementations + observed CC harness behavior in this session.

## Findings

### 1. PreToolUse hook payload shape

**Source:** `~/.claude/plugins/cache/superpowers-extended-cc-marketplace/superpowers-extended-cc/6.3.0/hooks/examples/pre-commit-check-tasks.sh`

Payload fields confirmed:
- `tool_name` (string) - e.g., "Bash", "Write", "Edit"
- `tool_input` (object) - tool-specific; `command` for Bash, `file_path` + `content` for Write
- `transcript_path` (string) - absolute path to session JSONL transcript

**`agent_id` field NOT present.** The hook cannot directly discriminate by calling subagent.

**Decision:** WORKAROUND. To discriminate by caller agent, the hook must parse `transcript_path` to find the most recent Agent dispatch and extract its `subagent_type` field. Implementation pattern from pre-commit-check-tasks.sh shows transcript parsing is feasible.

**Impact on Task 1:** Hook implementation must change. Was: `agent_id=$(jq -r '.agent_id')`. New: parse transcript, find last Agent dispatch, extract subagent_type. Heavier but viable.

### 2. Hook config schema

**Source:** Multiple `hooks.json` files inspected.

Hook config lives in **`hooks/hooks.json` separate file**, NOT inline in `plugin.json`. Schema:

```json
{
  "hooks": {
    "EventName": [
      {
        "matcher": "regex-or-empty",
        "hooks": [
          {"type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/path/to/script.sh"}
        ]
      }
    ]
  }
}
```

Events confirmed in use: SessionStart, Stop, Notification, PermissionRequest, UserPromptSubmit, PostToolUse. PreToolUse documented (used in pre-commit-check-tasks.sh example).

**Decision:** UPDATE plan. `plugin.json` should NOT have a `hooks` key (already removed in Task 0 commit). Add `hooks/hooks.json` in Task 1.

### 3. AskUserQuestion availability inside skills

**Source:** Direct observation across this session's brainstorming + writing-plans flows.

Skills run in main thread. Main thread has AskUserQuestion. Confirmed working: AskUserQuestion calls inside skill bodies render to user and capture response.

**Decision:** PROCEED. No changes needed.

**Caveat:** AskUserQuestion is NOT available inside subagents dispatched via Agent tool. This is fine; the design only uses AskUserQuestion in main-thread orchestrator skills (cycle, discuss).

### 4. `claude --print` stdin behavior

**Decision:** PROCEED via WORKAROUND. Smoke runner does NOT pipe stdin to interactive prompts. Instead, cycle skill supports env-var overrides: `LOOP_SPEC_NON_INTERACTIVE=1`, `LOOP_SPEC_ANSWER_TIER=quick`, `LOOP_SPEC_ANSWER_STYLE=auto`, `LOOP_SPEC_ANSWER_TITLE="..."`. Cycle skill detects env var and skips AskUserQuestion calls, reading answers from env. Standard pattern; doesn't require any CC harness probe.

## Summary

| Capability | Status | Action |
|------------|--------|--------|
| PreToolUse payload `agent_id` | ABSENT (workaround: parse transcript_path) | UPDATE Task 1 hook |
| Hook config location | `hooks/hooks.json` separate file | UPDATE Task 1 (was: register inline in plugin.json) |
| AskUserQuestion in skills | WORKS | PROCEED |
| `claude --print` + stdin | irrelevant | PROCEED with env-var override |

No BLOCKERS. Two WORKAROUNDS required (Task 1 hook + cycle skill env-var support).
