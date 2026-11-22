import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { Type } from "typebox";
import { Check } from "typebox/value";
import { fileURLToPath } from "node:url";
import { setTimeout as delay } from "node:timers/promises";
import { withOpenAIContextNetwork } from "./openai-context-network.ts";
import {
  inactiveModelId,
  readScenario,
  scenarioNames,
} from "./openai-context-scenarios.ts";
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
const settingsPath = join(agentDir, "settings.json");
let settingsWithExtension: string | undefined;
if (mode === "reload") {
  settingsWithExtension = await readFile(settingsPath, "utf8");
  const settings = parseRecord(settingsWithExtension);
  await writeFile(
    settingsPath,
    JSON.stringify({ ...settings, extensions: [] }),
  );
}
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
      contextWindows: {
        [model]: cachedWindow.tokens,
        [inactiveModelId]: cachedWindow.tokens,
      },
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

if (mode === "cached") {
  const listContextWindow = (...authArgs: string[]) => {
    const result = execFileSync(
      pi,
      ["--no-mcp", ...authArgs, "--list-models", model],
      { encoding: "utf8" },
    );
    return result
      .split("\n")
      .map((line) => line.trim().split(/\s+/u))
      .find(([provider, id]) => provider === "openai" && id === model)?.[2];
  };
  assert.deepEqual(
    {
      oauth: listContextWindow(),
      apiKey: listContextWindow(
        "--model",
        `openai/${model}`,
        "--api-key",
        "fixture",
      ),
    },
    { oauth: "530K", apiKey: "272K" },
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
const modelSchema = Type.Object({
  provider: Type.String(),
  id: Type.String(),
  contextWindow: Type.Integer(),
});
const modelStateSchema = Type.Object({ model: modelSchema });
const availableModelsSchema = Type.Object({ models: Type.Array(modelSchema) });

async function waitForWindow(
  readWindow: () => Promise<number | undefined>,
  expected: number | undefined,
): Promise<number | undefined> {
  const deadline = Date.now() + 6_000;
  let window = await readWindow();
  while (window !== expected && Date.now() < deadline) {
    // eslint-disable-next-line no-await-in-loop -- Compare successive states.
    await delay(50);
    // eslint-disable-next-line no-await-in-loop -- Requests observe the model in order.
    window = await readWindow();
  }
  return window;
}
const fixture = fileURLToPath(
  new URL("./openai-context-fixture.ts", import.meta.url),
);
const args = [
  "--no-session",
  "--no-mcp",
  "--no-skills",
  "--model",
  mode === "warm" ? "anthropic/claude-sonnet-4-6" : `openai/${model}`,
  "--context-probe-mode",
  mode,
];
await withOpenAIContextNetwork(
  { agentDir, models: [model, inactiveModelId], catalogue: scenario.catalogue },
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
        const readInactiveWindow = async () => {
          const result = await session.request({
            type: "get_available_models",
          });
          assert.ok(Check(availableModelsSchema, result));
          return result.models.find(
            (entry) =>
              entry.provider === "openai" && entry.id === inactiveModelId,
          )?.contextWindow;
        };
        if (mode === "manual-refresh") {
          const getCommands = await session.request({ type: "get_commands" });
          assert.ok(
            Check(
              Type.Object({
                commands: Type.Array(Type.Object({ name: Type.String() })),
              }),
              getCommands,
            ),
          );
          assert.deepEqual(
            getCommands.commands
              .map(({ name }) => name)
              .filter(
                (name) =>
                  name === "openai-context" || name === "openai-context-status",
              ),
            ["openai-context"],
          );
          assert.deepEqual(
            await session.request({
              type: "prompt",
              message: "/openai-context",
            }),
            { disposition: "handled" },
          );
          const before = await session.request({ type: "get_state" });
          assert.ok(Check(modelStateSchema, before));
          assert.deepEqual(
            await session.request({
              type: "prompt",
              message: "/openai-context refresh",
            }),
            { disposition: "handled" },
          );
          const after = await session.request({ type: "get_state" });
          const available = await session.request({
            type: "get_available_models",
          });
          assert.ok(Check(modelStateSchema, after));
          assert.ok(Check(availableModelsSchema, available));
          assert.deepEqual(
            {
              before: before.model.contextWindow,
              after: after.model.contextWindow,
              inactive: available.models.find(
                (entry) =>
                  entry.provider === "openai" && entry.id === inactiveModelId,
              )?.contextWindow,
              catalogueRequests: requests.filter(
                ({ path }) => path === "/v1/models",
              ).length,
            },
            {
              before: 530_000,
              after: 510_000,
              inactive: 510_000,
              catalogueRequests: 1,
            },
          );
          return;
        }
        if (mode === "warm") {
          const window = await waitForWindow(
            readInactiveWindow,
            scenario.expectedWindow,
          );
          const state = await session.request({ type: "get_state" });
          assert.ok(Check(modelStateSchema, state));
          assert.deepEqual(
            {
              provider: state.model.provider,
              window,
              catalogueRequests: requests.filter(
                ({ path }) => path === "/v1/models",
              ).length,
            },
            {
              provider: "anthropic",
              window: scenario.expectedWindow,
              catalogueRequests: 1,
            },
          );
          return;
        }
        if (settingsWithExtension !== undefined) {
          const readContextWindow = async () => {
            const state = await session.request({ type: "get_state" });
            assert.ok(Check(modelStateSchema, state));
            return state.model.contextWindow;
          };
          assert.notEqual(await readContextWindow(), scenario.expectedWindow);
          await writeFile(settingsPath, settingsWithExtension);
          await command("reload-openai-context");

          assert.equal(
            await waitForWindow(readContextWindow, scenario.expectedWindow),
            scenario.expectedWindow,
            "Apply the new account window after reload without a model turn",
          );
          await command("check-openai-context");
        }
        if (mode === "override") {
          assert.equal(
            await waitForWindow(readInactiveWindow, 510_000),
            510_000,
          );
        }
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
        if (mode === "offline" || mode === "api-key" || mode === "foreign") {
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
        if (
          scenario.offline !== true &&
          mode !== "api-key" &&
          mode !== "foreign"
        ) {
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
      mode === "warm" ? { ...env, ANTHROPIC_API_KEY: "fixture" } : env,
    ),
);
