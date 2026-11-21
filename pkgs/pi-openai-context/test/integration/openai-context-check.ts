import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { Type } from "typebox";
import { Check } from "typebox/value";
import { fileURLToPath } from "node:url";
import { withOpenAIContextNetwork } from "./openai-context-network.ts";
import { readScenario, scenarioNames } from "./openai-context-scenarios.ts";
import { parseRecord } from "@dotfiles/pi-integration-tests/protocol";
import { withPiRpc } from "@dotfiles/pi-integration-tests/rpc-session";

const [pi, model, mode, agentDir] = process.argv.slice(2);
if (pi === "--list-scenarios") {
  process.stdout.write(scenarioNames.join("\n") + "\n");
  process.exit(0);
}
assert.ok(
  pi !== undefined &&
    model !== undefined &&
    mode !== undefined &&
    agentDir !== undefined,
  "Pass Pi, the OpenAI model, the probe mode and the agent directory",
);

const scenario = readScenario(mode);
const { cachedWindow } = scenario;
if (mode === "renewed") {
  const authPath = join(agentDir, "auth.json");
  const auth = parseRecord(await readFile(authPath, "utf8"));
  const openai = parseRecord(JSON.stringify(auth.openai));
  await writeFile(
    authPath,
    JSON.stringify({ ...auth, openai: { ...openai, expires: 1 } }),
  );
}
if (mode === "oauth") {
  const settingsPath = join(agentDir, "settings.json");
  const settings = parseRecord(await readFile(settingsPath, "utf8"));
  await writeFile(
    settingsPath,
    JSON.stringify({ ...settings, defaultThinkingLevel: "low" }),
  );
}
if (cachedWindow !== undefined) {
  await writeFile(
    join(agentDir, "openai-context-cache.json"),
    JSON.stringify({
      grant: createHash("sha256").update("fixture").digest("hex"),
      refreshAfter: cachedWindow.stale === true ? 1 : Date.now() + 60_000,
      contextWindows: { [model]: cachedWindow.tokens },
    }),
    { mode: 0o600 },
  );
}
if (mode === "override") {
  await writeFile(
    join(agentDir, "models.json"),
    JSON.stringify({
      providers: {
        openai: {
          modelOverrides: {
            [model]: { contextWindow: 420_000, maxTokens: 146_000 },
          },
        },
      },
    }),
  );
}

const messagesSchema = Type.Object({
  messages: Type.Array(
    Type.Object({
      role: Type.String(),
      stopReason: Type.Optional(Type.String()),
      content: Type.Unknown(),
    }),
  ),
});
const thinkingStateSchema = Type.Object({ thinkingLevel: Type.String() });
const fixture = fileURLToPath(
  new URL("./openai-context-fixture.ts", import.meta.url),
);
const args = [
  "--no-session",
  "--no-mcp",
  "--no-skills",
  "--model",
  `openai/${model}`,
  "--context-probe-mode",
  mode,
];
await withOpenAIContextNetwork(
  { agentDir, models: [model], catalogue: scenario.catalogue },
  ({ env, requests, advertiseAccountWindow }) =>
    withPiRpc(
      pi,
      [
        ...args,
        "-e",
        fixture,
        ...(scenario.offline === true ? ["--offline"] : []),
      ],
      async (session) => {
        const command = async (name: string) => {
          await session.request({ type: "prompt", message: `/${name}` });
        };
        const prompt = async (
          turn: () => Promise<void> = () =>
            session.runTurn("Probe the Responses stream"),
        ) => {
          await turn();
          const history = await session.request({ type: "get_messages" });
          assert.ok(
            Check(messagesSchema, history),
            "Expected Pi message history",
          );
          const last = history.messages.at(-1);
          assert.deepEqual(
            last && {
              role: last.role,
              stopReason: last.stopReason,
              content: last.content,
            },
            {
              role: "assistant",
              stopReason: "stop",
              content: [
                {
                  type: "text",
                  text: "Fixture response",
                  textSignature: '{"v":1,"id":"msg_fixture"}',
                },
              ],
            },
          );
          await command("check-openai-context");
        };

        await prompt();
        if (mode === "offline" || mode === "api-key") {
          assert.deepEqual(
            requests.filter(
              ({ host, path }) =>
                host === "api.openai.com" && path === "/v1/models",
            ),
            [],
          );
        }
        if (mode === "override") {
          await command("remove-context-override");
          await prompt();
        }
        if (mode === "oauth") {
          // Changing the upstream value distinguishes cache reuse after token rotation.
          advertiseAccountWindow(620_000);
          await command("rotate-chatgpt-token");
          await session.request({ type: "new_session" });
          await prompt(() =>
            session.runCommandTurn("openai-context-programmatic-turn"),
          );
          await session.request({
            type: "set_thinking_level",
            level: "high",
          });
          const beforeOverride = await session.request({ type: "get_state" });
          assert.ok(Check(thinkingStateSchema, beforeOverride));
          assert.equal(beforeOverride.thinkingLevel, "high");
          await command("add-context-override");
          await prompt();
          const afterOverride = await session.request({ type: "get_state" });
          assert.ok(Check(thinkingStateSchema, afterOverride));
          assert.equal(
            afterOverride.thinkingLevel,
            beforeOverride.thinkingLevel,
          );
          await command("remove-context-override");
          await prompt();
          await command("change-chatgpt-registration");
          await prompt();
        }

        const authenticated = requests.filter(
          ({ host, path }) =>
            host === "api.openai.com" &&
            (path === "/v1/models" || path === "/v1/responses"),
        );
        assert.deepEqual(
          authenticated.filter(
            ({ authorization }) =>
              authorization !== "Bearer fixture" &&
              authorization !== "Bearer rotated",
          ),
          [],
        );
        if (scenario.offline !== true && mode !== "api-key") {
          assert.ok(
            authenticated.some(
              ({ path, authorization }) =>
                path === "/v1/models" &&
                authorization ===
                  (mode === "renewed" ? "Bearer rotated" : "Bearer fixture"),
            ),
            "Expected the account catalogue endpoint to receive the ChatGPT token",
          );
        }
        assert.deepEqual(
          requests.filter(({ path }) => path === "/v1/unexpected-redirect"),
          [],
        );
      },
      env,
    ),
);
