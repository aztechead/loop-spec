/**
 * loop-spec OpenCode plugin.
 *
 * Bridges the Claude Code environment and lifecycle hooks used by loop-spec
 * onto OpenCode's documented Plugin API:
 *
 *   Claude Code surface       OpenCode bridge
 *   -----------------------   -----------------------------------------------
 *   CLAUDE_* environment      shell.env
 *   active skill directory    tool.execute.after metadata from skill/read
 *   SessionStart              session.created + first chat.message barrier
 *   UserPromptSubmit          chat.message
 *   Stop (best effort)        session.idle
 *
 * OpenCode can run root and child sessions concurrently, and event callback
 * promises are not awaited by the runtime. Mutable state is therefore keyed by
 * sessionID, and chat.message awaits its own SessionStart initialization.
 * Injected context is an OpenCode text part, not provider wire-format content,
 * so OpenCode can translate it for Anthropic, OpenAI, Google, local models,
 * gateways, and other providers.
 *
 * Deliberately dependency-free: node builtins only. This .ts file also remains
 * valid JavaScript so the offline suite can execute it with stock node.
 */

import { spawn } from "node:child_process";
import * as path from "node:path";
import * as fs from "node:fs";
import { randomBytes } from "node:crypto";
import { fileURLToPath } from "node:url";

// The installer symlinks this file into the OpenCode config directory.
// Resolving that link recovers the package root for bundled hook paths.
const SELF = (() => {
  const filename = fileURLToPath(import.meta.url);
  try {
    return fs.realpathSync(filename);
  } catch {
    return filename;
  }
})();
const PKG_ROOT = path.resolve(path.dirname(SELF), "..", "..");
const HOOK_TIMEOUT_MS = 15000;
const SESSION_START_SCRIPTS = [
  "hooks/team/discipline-inject.sh",
  "hooks/team/grill-inject.sh",
  "hooks/team/simplicity-inject.sh",
  "hooks/team/rules-inject.sh",
  "hooks/team/micro-inject.sh",
];

/** Run a bundled hook and return additionalContext, failing open. */
function runHook(scriptRel, stdinPayload, cwd, env = {}) {
  return new Promise((resolve) => {
    try {
      const script = path.join(PKG_ROOT, scriptRel);
      const proc = spawn("bash", [script], {
        cwd,
        env: { ...process.env, ...env },
        detached: process.platform !== "win32",
      });
      let out = "";
      let settled = false;
      let timer;
      const settle = (value) => {
        if (settled) return;
        settled = true;
        if (timer) clearTimeout(timer);
        resolve(value);
      };
      timer = setTimeout(() => {
        try {
          if (process.platform !== "win32" && proc.pid) {
            process.kill(-proc.pid, "SIGKILL");
          } else {
            proc.kill("SIGKILL");
          }
        } catch {
          /* already gone */
        }
        settle(null);
      }, HOOK_TIMEOUT_MS);
      proc.stdout.on("data", (data) => (out += String(data)));
      // Some hooks exit before reading stdin. Swallow EPIPE but keep the
      // close/timeout lifecycle active so a child that merely closed stdin
      // cannot outlive the 15-second bound.
      proc.stdin.on("error", () => {});
      proc.on("error", () => settle(null));
      proc.on("close", (code) => {
        if (settled) return;
        if (code !== 0 || !out.trim()) return settle(null);
        try {
          // jq emits pretty-printed multiline JSON. If a hook logged first,
          // retry from each line that could begin the final JSON object.
          const trimmed = out.trim();
          let parsed;
          try {
            parsed = JSON.parse(trimmed);
          } catch {
            const lines = trimmed.split("\n");
            for (let i = lines.length - 1; i >= 0; i -= 1) {
              if (!lines[i].trimStart().startsWith("{")) continue;
              try {
                parsed = JSON.parse(lines.slice(i).join("\n"));
                break;
              } catch {
                /* keep looking */
              }
            }
          }
          const context = parsed?.hookSpecificOutput?.additionalContext;
          settle(typeof context === "string" && context ? context : null);
        } catch {
          settle(null);
        }
      });
      if (stdinPayload) proc.stdin.write(JSON.stringify(stdinPayload));
      proc.stdin.end();
    } catch {
      resolve(null);
    }
  });
}

export const LoopSpecPlugin = async (input) => {
  const projectDir = input?.directory || process.cwd();

  // Immutable package identity is safe process-wide. Project and skill values
  // are intentionally supplied per subprocess through hookEnv below.
  process.env.LOOP_SPEC_HARNESS = "opencode";
  process.env.CLAUDE_PLUGIN_ROOT = PKG_ROOT;

  const sessionStates = new Map();
  let partSequence = 0;

  function stateFor(sessionID) {
    const key = typeof sessionID === "string" && sessionID
      ? sessionID
      : "__default__";
    let state = sessionStates.get(key);
    if (!state) {
      state = {
        id: key,
        projectDir,
        skillDir: null,
        topLevel: undefined,
        initPromise: null,
        pendingContext: [],
      };
      sessionStates.set(key, state);
    }
    return state;
  }

  function applySessionInfo(state, info) {
    if (!info || typeof info !== "object") return;
    if (typeof info.directory === "string" && info.directory) {
      state.projectDir = info.directory;
    }
    state.topLevel = !info.parentID;
  }

  async function resolveState(sessionID) {
    const state = stateFor(sessionID);
    if (state.topLevel !== undefined || state.id === "__default__") return state;
    try {
      const response = await input?.client?.session?.get?.({
        path: { id: state.id },
      });
      const info = response?.data;
      if (info?.id === state.id) applySessionInfo(state, info);
    } catch {
      /* event data is preferred; leave root/child classification unknown */
    }
    return state;
  }

  function hookEnv(state, sessionID) {
    const env = {
      LOOP_SPEC_HARNESS: "opencode",
      CLAUDE_PLUGIN_ROOT: PKG_ROOT,
      CLAUDE_PROJECT_DIR: state.projectDir,
    };
    if (state.skillDir) env.CLAUDE_SKILL_DIR = state.skillDir;
    if (sessionID) {
      env.CLAUDE_CODE_SESSION_ID = sessionID;
      env.CLAUDE_SESSION_ID = sessionID;
    }
    return env;
  }

  function initializeSession(state) {
    if (state.topLevel === false) return Promise.resolve();
    if (state.initPromise) return state.initPromise;
    state.topLevel = true;
    state.initPromise = Promise.all(
      SESSION_START_SCRIPTS.map((script) =>
        runHook(script, null, state.projectDir, hookEnv(state, state.id))
      ),
    ).then((injected) => {
      for (const context of injected) {
        if (context) state.pendingContext.push(context);
      }
    }).catch(() => {
      /* fail-open */
    });
    return state.initPromise;
  }

  function setSkillDir(state, dir) {
    try {
      state.skillDir = fs.realpathSync(dir);
    } catch {
      state.skillDir = dir;
    }
  }

  return {
    // OpenCode mutates this output object into each shell process environment.
    "shell.env": async (hookInput, output) => {
      try {
        const state = await resolveState(hookInput?.sessionID);
        Object.assign(output.env, hookEnv(state, hookInput?.sessionID));
      } catch {
        /* fail-open */
      }
    },

    "tool.execute.after": async (hookInput, output) => {
      try {
        const state = await resolveState(hookInput?.sessionID);
        if (hookInput?.tool === "skill") {
          const dir = output?.metadata?.dir;
          const name = output?.metadata?.name;
          if (typeof name === "string" && name.startsWith("loop-spec-")) {
            const sourceDir = path.join(PKG_ROOT, "skills", name.slice("loop-spec-".length));
            if (fs.existsSync(path.join(sourceDir, "SKILL.md"))) {
              setSkillDir(state, sourceDir);
              return;
            }
          }
          if (typeof dir === "string" && dir) setSkillDir(state, dir);
          return;
        }
        if (hookInput?.tool === "read") {
          const filename = hookInput?.args?.filePath ?? hookInput?.args?.path;
          if (typeof filename !== "string" || path.basename(filename) !== "SKILL.md") return;
          const absolute = path.isAbsolute(filename)
            ? filename
            : path.resolve(state.projectDir, filename);
          setSkillDir(state, path.dirname(absolute));
        }
      } catch {
        /* fail-open */
      }
    },

    "chat.message": async (hookInput, output) => {
      try {
        const state = await resolveState(hookInput?.sessionID);
        // OpenCode does not await event hooks. This is the ordering barrier that
        // guarantees SessionStart context reaches the first root-session turn.
        if (state.topLevel === true) await initializeSession(state);

        const parts = Array.isArray(output?.parts) ? output.parts : [];
        const prompt = parts
          .filter((part) =>
            part?.type === "text" &&
            part?.synthetic !== true &&
            typeof part?.text === "string"
          )
          .map((part) => part.text)
          .join("\n");
        const injected = await runHook(
          "hooks/team/done-criteria.sh",
          { prompt },
          state.projectDir,
          hookEnv(state, hookInput?.sessionID),
        );
        if (injected) state.pendingContext.push(injected);

        if (state.pendingContext.length === 0) return;
        const content = state.pendingContext.splice(0).join("\n\n");
        // This is OpenCode's provider-neutral persisted Part shape. Do not
        // construct Anthropic, OpenAI, Google, or gateway messages directly.
        parts.push({
          id: `prt_loopspec${randomBytes(12).toString("hex")}${(partSequence += 1).toString(36)}`,
          sessionID: hookInput?.sessionID ?? output?.message?.sessionID ?? "",
          messageID: output?.message?.id ?? "",
          type: "text",
          text: `<loop-spec-context>\n${content}\n</loop-spec-context>`,
          synthetic: true,
        });
      } catch {
        /* fail-open */
      }
    },

    event: async ({ event }) => {
      try {
        if (event?.type === "session.created") {
          const info = event?.properties?.info ?? {};
          const state = stateFor(info?.id);
          applySessionInfo(state, info);
          if (state.topLevel === false) return;
          // Store the promise synchronously before the first await. A concurrent
          // chat.message call will await this exact initialization.
          await initializeSession(state);
          return;
        }

        if (event?.type === "session.deleted") {
          sessionStates.delete(event?.properties?.info?.id);
          return;
        }

        if (event?.type === "session.idle") {
          const sessionID = event?.properties?.sessionID ?? "opencode-session";
          const state = await resolveState(sessionID);
          if (state.topLevel !== true) return;
          await runHook(
            "hooks/team/session-end-learnings.sh",
            { session_id: sessionID, transcript_path: "" },
            state.projectDir,
            hookEnv(state, sessionID),
          );
        }
      } catch {
        /* fail-open */
      }
    },
  };
};
