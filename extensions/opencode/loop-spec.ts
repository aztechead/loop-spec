/**
 * loop-spec opencode plugin — bridges the Claude Code plugin surface onto
 * opencode (https://opencode.ai), so the same bash/jq/python3 machinery runs
 * under both harnesses from one source tree.
 *
 * Unlike pi, opencode natively provides most of what loop-spec needs: skills
 * load through the Agent Skills standard (`skill` tool; `.opencode/skills/`
 * and `~/.config/opencode/skills/` discovery), one-shot subagents exist
 * (`task` tool with the same {description, prompt, subagent_type} shape as
 * Claude Code's Agent tool), commands live in `commands/`, and questions go
 * through the `question` tool. What this plugin bridges is the remaining CC
 * plugin surface, each via a hook documented at https://opencode.ai/docs/plugins/:
 *
 *   CC surface                     opencode bridge here
 *   ---------------------------   ------------------------------------------
 *   ${CLAUDE_PLUGIN_ROOT}          `shell.env` hook: opencode merges the
 *                                  returned env into EVERY bash invocation
 *                                  (packages/opencode/src/tool/shell.ts
 *                                  spreads it over process.env) — the native
 *                                  equivalent of pi's command-prepend bridge
 *   ${CLAUDE_PROJECT_DIR}          same hook; the plugin input's `directory`
 *   ${CLAUDE_SKILL_DIR}            tracked: a `skill` tool call reports the
 *                                  loaded skill's dir in its result metadata
 *                                  (`tool.execute.after`), and a `read` of a
 *                                  SKILL.md sets it to that file's directory;
 *                                  both are realpath'd so a symlinked install
 *                                  (lib/opencode-install.sh) still resolves
 *                                  `${CLAUDE_SKILL_DIR}/../../lib/...`
 *   SessionStart hooks             `event` hook, session.created (top-level
 *                                  sessions only): runs the same inject
 *                                  scripts (discipline/grill/simplicity/
 *                                  rules/micro) in parallel and queues the
 *                                  collected additionalContext
 *   UserPromptSubmit hook          `chat.message` hook pipes the prompt
 *                                  through done-criteria.sh; queued context
 *                                  (inject + done-criteria) is delivered by
 *                                  appending a synthetic text part to the
 *                                  user message parts
 *   Stop hook                      `event` hook, session.idle: runs
 *                                  session-end-learnings.sh (best-effort;
 *                                  opencode has no blocking stop event)
 *   harness identity               LOOP_SPEC_HARNESS=opencode, which
 *                                  lib/harness.sh treats as authoritative
 *
 * NOT bridged (no opencode equivalent exists; skills degrade by contract
 * instead — see skills/shared/opencode-harness.md): agent teams (SendMessage,
 * named teammates), the Workflow tool, TaskCreate/TaskUpdate task lists, and
 * the blocking Stop guards (stop-deflection-guard.sh, adhoc-verify-guard.sh —
 * session.idle is fire-and-forget and cannot veto).
 *
 * Deliberately dependency-free: node builtins only, hook inputs typed as
 * `any`, so loading never requires an npm/bun install. Every bridge is
 * wrapped fail-open — a broken hook script must never take the session down
 * (same trap-'exit 0' contract the bash hooks follow under Claude Code).
 */

import { spawn } from "node:child_process";
import * as path from "node:path";
import * as fs from "node:fs";
import { fileURLToPath } from "node:url";

// realpathSync: the installer symlinks this file into
// <config>/plugins/loop-spec.ts; resolving the link recovers the real
// package root so hook-script paths and CLAUDE_PLUGIN_ROOT stay correct.
const SELF = (() => {
  const p = fileURLToPath(import.meta.url);
  try {
    return fs.realpathSync(p);
  } catch {
    return p;
  }
})();
const PKG_ROOT = path.resolve(path.dirname(SELF), "..", "..");
const HOOK_TIMEOUT_MS = 15000;

/** Run one bundled CC hook script (async — never blocks opencode's event
 *  loop) and resolve to its additionalContext, or null on any failure
 *  (fail-open). */
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

export const LoopSpecPlugin = async (input: any) => {
  const projectDir: string = input?.directory || process.cwd();

  // Harness identity + plugin root on our own process env too (opencode
  // spawns bash from this process; shell.env below is the guaranteed path).
  process.env.LOOP_SPEC_HARNESS = "opencode";
  process.env.CLAUDE_PLUGIN_ROOT = PKG_ROOT;
  process.env.CLAUDE_PROJECT_DIR = projectDir;

  // Context queued by bridged hooks, delivered on the next user message
  // (opencode's equivalent of CC's additionalContext injection point).
  let pendingContext: string[] = [];
  // Sessions this plugin has already run the SessionStart bridge for.
  const startedSessions = new Set<string>();

  /** Track the active skill directory. Under opencode a skill loads through
   *  the native `skill` tool (result metadata carries the dir) or by reading
   *  its SKILL.md; the last one wins — exactly what ${CLAUDE_SKILL_DIR} means
   *  in the skill bodies. realpath resolves symlinked installs. */
  function setSkillDir(dir: string) {
    try {
      process.env.CLAUDE_SKILL_DIR = fs.realpathSync(dir);
    } catch {
      process.env.CLAUDE_SKILL_DIR = dir;
    }
  }

  return {
    /** Env delivery into every bash call — the documented `shell.env` plugin
     *  hook; opencode merges output.env over process.env for the child. */
    "shell.env": async (_input: any, output: any) => {
      try {
        output.env.LOOP_SPEC_HARNESS = "opencode";
        output.env.CLAUDE_PLUGIN_ROOT = PKG_ROOT;
        output.env.CLAUDE_PROJECT_DIR =
          process.env.CLAUDE_PROJECT_DIR || projectDir;
        if (process.env.CLAUDE_SKILL_DIR) {
          output.env.CLAUDE_SKILL_DIR = process.env.CLAUDE_SKILL_DIR;
        }
      } catch {
        /* fail-open */
      }
    },

    "tool.execute.after": async (inp: any, output: any) => {
      try {
        // Native skill tool: metadata is {name, dir} (opencode's SkillTool).
        if (inp?.tool === "skill") {
          const dir = output?.metadata?.dir;
          if (typeof dir === "string" && dir) setSkillDir(dir);
          return;
        }
        // Cross-skill SKILL.md reads shift the active dir, same as under pi
        // (skills/shared/pi-harness.md documents the re-export rule).
        if (inp?.tool === "read") {
          const p = inp?.args?.filePath ?? inp?.args?.path;
          if (typeof p !== "string" || path.basename(p) !== "SKILL.md") return;
          const abs = path.isAbsolute(p)
            ? p
            : path.resolve(process.env.CLAUDE_PROJECT_DIR || projectDir, p);
          setSkillDir(path.dirname(abs));
        }
      } catch {
        /* fail-open */
      }
    },

    /** UserPromptSubmit bridge + queued-context delivery. */
    "chat.message": async (inp: any, output: any) => {
      try {
        const parts: any[] = Array.isArray(output?.parts) ? output.parts : [];
        const promptText = parts
          .filter((p) => p?.type === "text" && typeof p?.text === "string")
          .map((p) => p.text)
          .join("\n");
        const injected = await runHook(
          "hooks/team/done-criteria.sh",
          { prompt: promptText },
          process.env.CLAUDE_PROJECT_DIR || projectDir
        );
        if (injected) pendingContext.push(injected);

        if (pendingContext.length === 0) return;
        const content = pendingContext.join("\n\n");
        pendingContext = [];
        // Synthetic text part appended to the user message — directives for
        // the model, marked synthetic so UIs can de-emphasize it.
        parts.push({
          id: `prt_loopspec${Date.now().toString(36)}`,
          sessionID: inp?.sessionID ?? output?.message?.sessionID ?? "",
          messageID: output?.message?.id ?? "",
          type: "text",
          text: `<loop-spec-context>\n${content}\n</loop-spec-context>`,
          synthetic: true,
        });
      } catch {
        /* fail-open */
      }
    },

    event: async ({ event }: any) => {
      try {
        // SessionStart bridge: top-level sessions only (subagent sessions
        // carry parentID and must not re-trigger the inject scripts).
        if (event?.type === "session.created") {
          const info = event?.properties?.info ?? {};
          if (info?.parentID) return;
          const id = typeof info?.id === "string" ? info.id : "";
          if (id && startedSessions.has(id)) return;
          if (id) startedSessions.add(id);
          const cwd =
            typeof info?.directory === "string" && info.directory
              ? info.directory
              : projectDir;
          process.env.CLAUDE_PROJECT_DIR = cwd;
          // Parallel: session start pays for the slowest hook, not the sum.
          const injected = await Promise.all(
            [
              "hooks/team/discipline-inject.sh",
              "hooks/team/grill-inject.sh",
              "hooks/team/simplicity-inject.sh",
              "hooks/team/rules-inject.sh",
              "hooks/team/micro-inject.sh",
            ].map((script) => runHook(script, null, cwd))
          );
          for (const c of injected) if (c) pendingContext.push(c);
          return;
        }

        // Stop bridge: fire-and-forget learnings pass when a top-level
        // session goes idle (opencode's closest analogue to CC's Stop hook).
        if (event?.type === "session.idle") {
          const sessionID = event?.properties?.sessionID ?? "opencode-session";
          await runHook(
            "hooks/team/session-end-learnings.sh",
            { session_id: sessionID, transcript_path: "" },
            process.env.CLAUDE_PROJECT_DIR || projectDir
          );
        }
      } catch {
        /* fail-open */
      }
    },
  };
};
