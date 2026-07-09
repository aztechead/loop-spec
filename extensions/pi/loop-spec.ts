/**
 * loop-spec pi extension — bridges the Claude Code plugin surface onto pi
 * (https://pi.dev), so the same bash/jq/python3 machinery runs under both
 * harnesses from one source tree.
 *
 * What Claude Code provides natively that pi does not, and how this file
 * bridges each piece:
 *
 *   CC surface                     pi bridge here
 *   ---------------------------   ------------------------------------------
 *   ${CLAUDE_PLUGIN_ROOT}          process.env set once at load (pi's bash
 *                                  tool inherits the pi process environment)
 *   ${CLAUDE_PROJECT_DIR}          process.env set on session_start (ctx.cwd)
 *   ${CLAUDE_SKILL_DIR}            tracked: every `read` of a SKILL.md sets it
 *                                  to that file's directory — under pi the
 *                                  model enters a skill by reading its
 *                                  SKILL.md, so the last one read is the
 *                                  active skill
 *   SessionStart hooks             session_start runs the same inject scripts
 *                                  (discipline/grill/simplicity/rules) and the
 *                                  collected additionalContext is delivered on
 *                                  the next before_agent_start
 *   UserPromptSubmit hook          input event pipes the prompt through
 *                                  done-criteria.sh, same delivery path
 *   Stop hook                      session_shutdown runs
 *                                  session-end-learnings.sh (best-effort)
 *   harness identity               LOOP_SPEC_HARNESS=pi, which lib/harness.sh
 *                                  treats as authoritative
 *
 * NOT bridged (no pi equivalent exists; skills degrade by contract instead —
 * see skills/shared/pi-harness.md): the Agent/subagent tool, agent teams,
 * the Workflow tool, TaskCreate/TaskUpdate, AskUserQuestion, and
 * restrict-agent-paths.sh (only meaningful when subagents exist).
 *
 * Deliberately dependency-free: node builtins only, `pi` typed as `any`, so
 * loading never requires an npm install. Every bridge is wrapped fail-open —
 * a broken hook script must never take the session down (same trap-'exit 0'
 * contract the bash hooks follow under Claude Code).
 */

import { spawnSync } from "node:child_process";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const PKG_ROOT = path.resolve(HERE, "..", "..");

/** Run one bundled CC hook script and return its additionalContext, if any. */
function runHook(
  scriptRel: string,
  stdinPayload: object | null,
  cwd: string
): string | null {
  try {
    const script = path.join(PKG_ROOT, scriptRel);
    const proc = spawnSync("bash", [script], {
      cwd,
      input: stdinPayload ? JSON.stringify(stdinPayload) : "",
      encoding: "utf8",
      timeout: 15000,
      env: process.env,
    });
    if (proc.status !== 0 || !proc.stdout) return null;
    // Hooks emit a single JSON object; tolerate leading noise by parsing the
    // last non-empty line (matches how CC consumes hook stdout).
    const lines = proc.stdout.trim().split("\n");
    const last = lines[lines.length - 1];
    const parsed = JSON.parse(last);
    const ctx = parsed?.hookSpecificOutput?.additionalContext;
    return typeof ctx === "string" && ctx.length > 0 ? ctx : null;
  } catch {
    return null; // fail-open: injection is an accelerator, never a gate
  }
}

export default function (pi: any) {
  // Harness identity + plugin root, before anything else runs. pi's bash tool
  // spawns children from this process, so exports here reach every skill
  // command. lib/harness.sh keys its `pi` answer off LOOP_SPEC_HARNESS.
  process.env.LOOP_SPEC_HARNESS = "pi";
  process.env.CLAUDE_PLUGIN_ROOT = PKG_ROOT;

  // Context queued by hooks, delivered on the next agent start (pi's
  // equivalent of CC's additionalContext injection point).
  let pendingContext: string[] = [];

  pi.on("session_start", async (_event: any, ctx: any) => {
    try {
      const cwd = ctx?.cwd || process.cwd();
      process.env.CLAUDE_PROJECT_DIR = cwd;
      for (const script of [
        "hooks/team/discipline-inject.sh",
        "hooks/team/grill-inject.sh",
        "hooks/team/simplicity-inject.sh",
        "hooks/team/rules-inject.sh",
      ]) {
        const injected = runHook(script, null, cwd);
        if (injected) pendingContext.push(injected);
      }
    } catch {
      /* fail-open */
    }
  });

  pi.on("input", async (event: any, ctx: any) => {
    try {
      const cwd = ctx?.cwd || process.cwd();
      // CC shape: UserPromptSubmit hooks receive {prompt} on stdin.
      const injected = runHook(
        "hooks/team/done-criteria.sh",
        { prompt: event?.text ?? "" },
        cwd
      );
      if (injected) pendingContext.push(injected);
    } catch {
      /* fail-open */
    }
    return { action: "continue" };
  });

  pi.on("before_agent_start", async (_event: any, _ctx: any) => {
    if (pendingContext.length === 0) return;
    const content = pendingContext.join("\n\n");
    pendingContext = [];
    return {
      message: {
        customType: "loop-spec-context",
        content,
        display: false, // directives for the model; keep the TUI transcript clean
      },
    };
  });

  // Active-skill tracking: under pi the model enters a skill by reading its
  // SKILL.md (progressive disclosure / the /skill: command expands to it), so
  // the directory of the last SKILL.md read is the active skill dir. That is
  // exactly what ${CLAUDE_SKILL_DIR} means in the skill bodies.
  pi.on("tool_call", async (event: any, _ctx: any) => {
    try {
      if (event?.toolName !== "read") return;
      const p =
        event?.input?.path ?? event?.input?.file_path ?? event?.input?.filePath;
      if (typeof p !== "string" || path.basename(p) !== "SKILL.md") return;
      const abs = path.isAbsolute(p)
        ? p
        : path.resolve(process.env.CLAUDE_PROJECT_DIR || process.cwd(), p);
      process.env.CLAUDE_SKILL_DIR = path.dirname(abs);
    } catch {
      /* fail-open */
    }
  });

  pi.on("session_shutdown", async (_event: any, ctx: any) => {
    try {
      const cwd = ctx?.cwd || process.cwd();
      let sessionFile = "";
      try {
        sessionFile = ctx?.sessionManager?.getSessionFile?.() ?? "";
      } catch {
        /* ephemeral session */
      }
      // Minimal CC Stop payload; the script's heuristics degrade gracefully
      // when the transcript format is not CC's.
      runHook(
        "hooks/team/session-end-learnings.sh",
        { session_id: sessionFile || "pi-session", transcript_path: sessionFile },
        cwd
      );
    } catch {
      /* fail-open */
    }
  });
}
