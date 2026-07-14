import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";

const fail = (message) => {
  console.error(message);
  process.exit(1);
};
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "loop-spec-opencode-plugin-"));
const projects = ["anthropic", "openai", "google"].map((name) => {
  const dir = path.join(tmp, name);
  fs.mkdirSync(path.join(dir, ".loop-spec"), { recursive: true });
  return dir;
});

try {
  const { LoopSpecPlugin } = await import(pathToFileURL(process.env.PLUGIN_PATH).href);
  const sessions = new Map();
  const client = {
    session: {
      get: async ({ path: requestPath }) => ({ data: sessions.get(requestPath.id) }),
    },
  };
  const hooks = await LoopSpecPlugin({ directory: projects[0], client });
  const realNow = Date.now;
  Date.now = () => 1234567890;
  const providers = [
    ["ses_anthropic", "anthropic", "claude-sonnet-4-6", projects[0]],
    ["ses_openai", "openai", "gpt-5.6", projects[1]],
    ["ses_google", "google", "gemini-3-pro", projects[2]],
  ];
  let firstGeneratedID;

  for (const [sessionID, providerID, modelID, directory] of providers) {
    const info = { id: sessionID, directory };
    sessions.set(sessionID, info);
    // OpenCode does not await event hooks. chat.message must synchronize with
    // initialization itself instead of relying on this promise's completion.
    const created = hooks.event({ event: { type: "session.created", properties: { info } } });
    const output = {
      message: {
        id: `msg_${providerID}`,
        sessionID,
        role: "user",
        time: { created: Date.now() },
        agent: "build",
        model: { providerID, modelID },
      },
      parts: [{
        id: `prt_input_${providerID}`,
        sessionID,
        messageID: `msg_${providerID}`,
        type: "text",
        text: "provider-neutral prompt",
      }],
    };
    await hooks["chat.message"](
      { sessionID, model: { providerID, modelID } },
      output,
    );
    await created;
    const injected = output.parts.find((part) => part.synthetic === true);
    if (!injected?.text.includes("GRILL MODE ACTIVE")) {
      fail(`${providerID}: multiline SessionStart context was not injected into the first message`);
    }
    if (injected.sessionID !== sessionID || injected.messageID !== output.message.id) {
      fail(`${providerID}: injected text part does not carry OpenCode message identifiers`);
    }
    if (!firstGeneratedID) firstGeneratedID = injected.id;
  }

  // Part IDs are global primary keys in OpenCode, so separate plugin instances
  // must not generate the same first ID even in the same millisecond.
  const secondID = "ses_second_instance";
  const secondInfo = { id: secondID, directory: projects[0] };
  sessions.set(secondID, secondInfo);
  const secondHooks = await LoopSpecPlugin({ directory: projects[0], client });
  await secondHooks.event({
    event: { type: "session.created", properties: { info: secondInfo } },
  });
  const secondOutput = {
    message: {
      id: "msg_second",
      sessionID: secondID,
      role: "user",
      time: { created: Date.now() },
      agent: "build",
      model: { providerID: "openai", modelID: "gpt-5.6" },
    },
    parts: [{
      id: "prt_input_second",
      sessionID: secondID,
      messageID: "msg_second",
      type: "text",
      text: "second plugin instance",
    }],
  };
  await secondHooks["chat.message"](
    { sessionID: secondID, model: secondOutput.message.model },
    secondOutput,
  );
  const secondGeneratedID = secondOutput.parts.find((part) => part.synthetic)?.id;
  if (!secondGeneratedID?.startsWith("prt_") || secondGeneratedID === firstGeneratedID) {
    fail("synthetic part IDs collided across plugin instances");
  }
  Date.now = realNow;

  const skillA = path.join(tmp, "skill-a");
  const skillB = path.join(tmp, "skill-b");
  fs.mkdirSync(skillA);
  fs.mkdirSync(skillB);
  await hooks["tool.execute.after"](
    { tool: "skill", sessionID: "ses_anthropic", callID: "call_a", args: {} },
    { title: "", output: "", metadata: { dir: skillA } },
  );
  await hooks["tool.execute.after"](
    { tool: "skill", sessionID: "ses_openai", callID: "call_b", args: {} },
    { title: "", output: "", metadata: { dir: skillB } },
  );
  const envA = { env: {} };
  const envB = { env: {} };
  await hooks["shell.env"]({ cwd: projects[0], sessionID: "ses_anthropic" }, envA);
  await hooks["shell.env"]({ cwd: projects[1], sessionID: "ses_openai" }, envB);
  if (envA.env.CLAUDE_SKILL_DIR !== fs.realpathSync(skillA) ||
      envB.env.CLAUDE_SKILL_DIR !== fs.realpathSync(skillB)) {
    fail("shell.env leaked the active skill directory between sessions");
  }
  if (envA.env.CLAUDE_PROJECT_DIR !== projects[0] || envB.env.CLAUDE_PROJECT_DIR !== projects[1]) {
    fail("shell.env leaked the project directory between sessions");
  }
  await hooks["tool.execute.after"](
    { tool: "skill", sessionID: "ses_anthropic", callID: "call_adapter", args: {} },
    { title: "", output: "", metadata: { name: "loop-spec-cycle", dir: skillA } },
  );
  const adapterEnv = { env: {} };
  await hooks["shell.env"]({ cwd: projects[0], sessionID: "ses_anthropic" }, adapterEnv);
  const packageRoot = path.resolve(path.dirname(process.env.PLUGIN_PATH), "..", "..");
  if (adapterEnv.env.CLAUDE_SKILL_DIR !== path.join(packageRoot, "skills", "cycle")) {
    fail("namespaced skill adapter did not map CLAUDE_SKILL_DIR to its source skill");
  }

  const childID = "ses_child";
  const child = { id: childID, parentID: "ses_anthropic", directory: projects[0] };
  sessions.set(childID, child);
  await hooks.event({ event: { type: "session.created", properties: { info: child } } });
  // An SDK error envelope is not session info. Unknown sessions must not run
  // root-only hooks or be permanently classified as roots.
  await hooks.event({ event: { type: "session.idle", properties: { sessionID: "ses_unknown" } } });
  await hooks.event({ event: { type: "session.idle", properties: { sessionID: childID } } });
  await hooks.event({ event: { type: "session.idle", properties: { sessionID: "ses_anthropic" } } });
  const learningFile = path.join(projects[0], ".loop-spec", "learnings.jsonl");
  const learnings = fs.readFileSync(learningFile, "utf8").trim().split("\n").map(JSON.parse);
  if (learnings.length !== 1 || learnings[0].sessionId !== "ses_anthropic") {
    fail("session.idle processed a child session or did not pass the root session id");
  }

  // done-criteria exits before reading stdin outside loop-spec projects. A
  // large prompt must fail open rather than surface an unhandled stdin EPIPE.
  const noLoopProject = path.join(tmp, "no-loop-spec");
  fs.mkdirSync(noLoopProject);
  const epipeID = "ses_epipe";
  const epipeInfo = { id: epipeID, directory: noLoopProject };
  sessions.set(epipeID, epipeInfo);
  await hooks.event({ event: { type: "session.created", properties: { info: epipeInfo } } });
  await hooks["chat.message"](
    { sessionID: epipeID, model: { providerID: "openai", modelID: "gpt-5.6" } },
    {
      message: { id: "msg_epipe", sessionID: epipeID },
      parts: [{
        id: "prt_epipe",
        sessionID: epipeID,
        messageID: "msg_epipe",
        type: "text",
        text: "x".repeat(4 * 1024 * 1024),
      }],
    },
  );

  console.log("runtime-ok");
} finally {
  fs.rmSync(tmp, { recursive: true, force: true });
}
