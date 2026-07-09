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
 *   ${CLAUDE_PLUGIN_ROOT}          process.env set once at load, AND exported
 *                                  into every bash command via the documented
 *                                  tool_call input mutation (pi docs show
 *                                  prepending to event.input.command) — the
 *                                  prepend guarantees delivery even if pi
 *                                  spawns bash with a curated environment
 *   ${CLAUDE_PROJECT_DIR}          same two paths, set on session_start (ctx.cwd)
 *   ${CLAUDE_SKILL_DIR}            tracked: every `read` of a SKILL.md sets it
 *                                  to that file's directory — under pi the
 *                                  model enters a skill by reading its
 *                                  SKILL.md, so the last one read is the
 *                                  active skill (cross-skill SKILL.md reads
 *                                  shift it; skills/shared/pi-harness.md
 *                                  documents the re-export rule for that)
 *   SessionStart hooks             session_start runs the same inject scripts
 *                                  (discipline/grill/simplicity/rules) — in
 *                                  parallel, async (never blocks pi's event
 *                                  loop) — and the collected additionalContext
 *                                  is delivered on the next before_agent_start
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

import { spawn } from "node:child_process";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const PKG_ROOT = path.resolve(HERE, "..", "..");
const HOOK_TIMEOUT_MS = 15000;

/** Single-quote a value for safe interpolation into a bash command line. */
function shq(s: string): string {
  return "'" + s.replace(/'/g, "'\\''") + "'";
}

/** Run one bundled CC hook script (async — never blocks pi's event loop) and
 *  resolve to its additionalContext, or null on any failure (fail-open). */
function runHook(
  scriptRel: string,
  stdinPayload: object | null,
  cwd: string
): Promise<string | null> {
  return new Promise((resolve) => {
    try {
      const script = path.join(PKG_ROOT, scriptRel);
      const proc = spawn("bash", [script], { cwd, env: process.env });
      let out = "";
      const timer = setTimeout(() => {
        try {
          proc.kill("SIGKILL");
        } catch {
          /* already gone */
        }
        resolve(null);
      }, HOOK_TIMEOUT_MS);
      proc.stdout.on("data", (d: unknown) => (out += String(d)));
      proc.on("error", () => {
        clearTimeout(timer);
        resolve(null);
      });
      proc.on("close", (code: number | null) => {
        clearTimeout(timer);
        if (code !== 0 || !out.trim()) return resolve(null);
        try {
          // Hooks emit a single JSON object; tolerate leading noise by parsing
          // the last non-empty line (matches how CC consumes hook stdout).
          const lines = out.trim().split("\n");
          const parsed = JSON.parse(lines[lines.length - 1]);
          const ctx = parsed?.hookSpecificOutput?.additionalContext;
          resolve(typeof ctx === "string" && ctx.length > 0 ? ctx : null);
        } catch {
          resolve(null); // fail-open: injection is an accelerator, never a gate
        }
      });
      if (stdinPayload) proc.stdin.write(JSON.stringify(stdinPayload));
      proc.stdin.end();
    } catch {
      resolve(null);
    }
  });
}

export default function (pi: any) {
  // Harness identity + plugin root, before anything else runs. Set on
  // process.env (pi spawns bash from this process) AND re-exported into every
  // bash command below, so the bridge holds even if pi curates the child env.
  process.env.LOOP_SPEC_HARNESS = "pi";
  process.env.CLAUDE_PLUGIN_ROOT = PKG_ROOT;

  // Context queued by hooks, delivered on the next agent start (pi's
  // equivalent of CC's additionalContext injection point).
  let pendingContext: string[] = [];

  pi.on("session_start", async (_event: any, ctx: any) => {
    try {
      const cwd = ctx?.cwd || process.cwd();
      process.env.CLAUDE_PROJECT_DIR = cwd;
      // Parallel: session start pays for the slowest hook, not the sum.
      const injected = await Promise.all(
        [
          "hooks/team/discipline-inject.sh",
          "hooks/team/grill-inject.sh",
          "hooks/team/simplicity-inject.sh",
          "hooks/team/rules-inject.sh",
        ].map((script) => runHook(script, null, cwd))
      );
      for (const c of injected) if (c) pendingContext.push(c);
    } catch {
      /* fail-open */
    }
  });

  pi.on("input", async (event: any, ctx: any) => {
    try {
      const cwd = ctx?.cwd || process.cwd();
      // CC shape: UserPromptSubmit hooks receive {prompt} on stdin.
      const injected = await runHook(
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

  pi.on("tool_call", async (event: any, _ctx: any) => {
    try {
      // Env delivery into bash (documented mutation pattern: pi's docs prepend
      // to event.input.command). Guarantees the skill scripts see the bridge
      // vars regardless of how pi builds the child environment.
      if (event?.toolName === "bash" && typeof event?.input?.command === "string") {
        const exports = [
          `LOOP_SPEC_HARNESS='pi'`,
          `CLAUDE_PLUGIN_ROOT=${shq(PKG_ROOT)}`,
          `CLAUDE_PROJECT_DIR=${shq(process.env.CLAUDE_PROJECT_DIR || process.cwd())}`,
        ];
        if (process.env.CLAUDE_SKILL_DIR) {
          exports.push(`CLAUDE_SKILL_DIR=${shq(process.env.CLAUDE_SKILL_DIR)}`);
        }
        event.input.command = `export ${exports.join(" ")}\n${event.input.command}`;
        return;
      }

      // Active-skill tracking: under pi the model enters a skill by reading its
      // SKILL.md (progressive disclosure / the /skill: command expands to it),
      // so the directory of the last SKILL.md read is the active skill dir —
      // exactly what ${CLAUDE_SKILL_DIR} means in the skill bodies.
      if (event?.toolName !== "read") return;
      const p = event?.input?.path;
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
      // Minimal CC Stop payload; the script fail-opens and its heuristics
      // degrade gracefully when the transcript format is not CC's.
      await runHook(
        "hooks/team/session-end-learnings.sh",
        { session_id: sessionFile || "pi-session", transcript_path: sessionFile },
        cwd
      );
    } catch {
      /* fail-open */
    }
  });
}
