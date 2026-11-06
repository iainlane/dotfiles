import { exportedFunction } from "./protocol.js";
import assert from "node:assert/strict";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import {
  fauxAssistantMessage,
  fauxProvider,
  fauxText,
  fauxToolCall,
  getCurrentTools,
} from "@earendil-works/pi-ai";
import {
  createAgentSession,
  DefaultResourceLoader,
  getAgentDir,
  ModelRuntime,
  SessionManager,
  SettingsManager,
  type ExtensionAPI,
} from "@earendil-works/pi-coding-agent";

export default function permissionContracts(pi: ExtensionAPI): void {
  pi.registerCommand("dotfiles-permission-contracts", {
    handler: async () => {
      const cwd = await mkdtemp(join(tmpdir(), "pi-permissions-"));
      const agentDir = getAgentDir();
      const autoReview = exportedFunction(
        await import(
          pathToFileURL(`${process.env.PI_AUTO_REVIEW_ROOT}/dist/index.js`).href
        ),
        "default",
      );
      const permissions = exportedFunction(
        await import(
          pathToFileURL(`${process.env.PI_PERMISSIONS_ROOT}/src/index.ts`).href
        ),
        "default",
      );
      const main = fauxProvider({
        provider: "permission-main-fixture",
        models: [{ id: "main" }],
      });
      const reviewer = fauxProvider({
        provider: "permission-review-fixture",
        models: [{ id: "reviewer" }],
      });
      const config = join(
        agentDir,
        "extensions/pi-permission-auto-review/config.json",
      );
      mkdirSync(join(config, ".."), { recursive: true });
      writeFileSync(
        config,
        JSON.stringify({
          provider: reviewer.getModel().provider,
          model: reviewer.getModel().id,
          reasoning: "off",
        }),
      );
      const outcomes = ["allow", "deny"] as const;
      main.setResponses(
        outcomes.flatMap((outcome) => [
          fauxAssistantMessage(
            [
              fauxToolCall(
                "bash",
                { command: `printf reviewed > shell-${outcome}.txt` },
                { id: `shell-${outcome}` },
              ),
              fauxToolCall(
                "write",
                { path: `direct-${outcome}.txt`, content: "direct" },
                { id: `direct-${outcome}` },
              ),
            ],
            { stopReason: "toolUse" },
          ),
          fauxAssistantMessage(fauxText("Done.")),
        ]),
      );
      const investigationTools: string[][] = [];
      reviewer.setResponses(
        outcomes.map((outcome) => (context) => {
          investigationTools.push(
            getCurrentTools(context.messages).map((tool) => tool.name),
          );
          return fauxAssistantMessage(
            fauxText(
              JSON.stringify({ outcome, rationale: "Fixture verdict." }),
            ),
          );
        }),
      );
      const settingsManager = SettingsManager.inMemory({
        compaction: { enabled: false },
        retry: { enabled: false },
      });
      const resourceLoader = new DefaultResourceLoader({
        cwd,
        agentDir,
        settingsManager,
        extensionFactories: [
          (api) => {
            autoReview(api);
          },
          (api) => {
            permissions(api);
          },
        ],
        noExtensions: true,
        noSkills: true,
        noThemes: true,
        noPromptTemplates: true,
        noContextFiles: true,
      });
      await resourceLoader.reload();
      const modelRuntime = await ModelRuntime.create({
        authPath: join(agentDir, "auth.json"),
        modelsPath: null,
        modelsStorePath: join(agentDir, "models-cache.json"),
        allowModelNetwork: false,
        refreshOnCreate: false,
      });
      for (const provider of [main, reviewer]) {
        modelRuntime.registerNativeProvider(provider.provider);
      }
      const createSession = () =>
        createAgentSession({
          cwd,
          agentDir,
          modelRuntime,
          model: main.getModel(),
          thinkingLevel: "off",
          tools: ["bash", "write"],
          resourceLoader,
          sessionManager: SessionManager.inMemory(cwd),
          settingsManager,
        });
      const initial = await createSession();
      let session = initial.session;
      const errors: unknown[] = [];
      const notices: string[] = [];
      try {
        await session.bindExtensions({
          mode: "rpc",
          uiContext: {
            ...session.extensionRunner.getUIContext(),
            notify: (message) => notices.push(message),
          },
          onError: (error) => errors.push(error),
        });
        await session.prompt("Perform the allowed fixture actions.", {
          source: "rpc",
        });
        await session.prompt("Perform the denied fixture actions.", {
          source: "rpc",
        });
        await session.waitForIdle();
        assert.deepStrictEqual(
          {
            errors,
            loadErrors: initial.extensionsResult.errors,
            reviewCalls: reviewer.state.callCount,
            investigationTools,
            files: {
              allowed: readFileSync(join(cwd, "shell-allow.txt"), "utf8"),
              denied: existsSync(join(cwd, "shell-deny.txt")),
              direct: outcomes.map((outcome) =>
                readFileSync(join(cwd, `direct-${outcome}.txt`), "utf8"),
              ),
            },
            results: session.messages
              .filter((message) => message.role === "toolResult")
              .map(({ toolCallId, isError }) => ({ toolCallId, isError })),
          },
          {
            errors: [],
            loadErrors: [],
            reviewCalls: 2,
            investigationTools: [[], []],
            files: {
              allowed: "reviewed",
              denied: false,
              direct: ["direct", "direct"],
            },
            results: [
              { toolCallId: "shell-allow", isError: false },
              { toolCallId: "direct-allow", isError: false },
              { toolCallId: "shell-deny", isError: true },
              { toolCallId: "direct-deny", isError: false },
            ],
          },
        );
        await session.prompt("/auto-stats", { source: "rpc" });
        assert.match(notices[0] ?? "", /^Investigation: unavailable,/m);

        await session.extensionRunner.emit({
          type: "session_shutdown",
          reason: "quit",
        });
        session.dispose();
        await resourceLoader.reload();
        const reopened = await createSession();
        session = reopened.session;
        await session.bindExtensions({
          mode: "rpc",
          uiContext: {
            ...session.extensionRunner.getUIContext(),
            notify: (message) => notices.push(message),
          },
          onError: (error) => errors.push(error),
        });
        await session.prompt("/auto-stats", { source: "rpc" });
        assert.deepStrictEqual(
          {
            errors,
            loadErrors: reopened.extensionsResult.errors,
            mainCalls: main.state.callCount,
            reviewCalls: reviewer.state.callCount,
            reports: notices.map((message) =>
              message
                .split("\n")
                .filter((line) =>
                  /^(Auto-review$|Allowed\s|Refused\s|No automatic decision\s)/.test(
                    line,
                  ),
                )
                .map((line) => line.trim().replaceAll(/\s{2,}/g, " | ")),
            ),
          },
          {
            errors: [],
            loadErrors: [],
            mainCalls: 4,
            reviewCalls: 2,
            reports: [
              [
                "Auto-review",
                "Allowed | 1 | 1",
                "Refused | 1 | 1",
                "No automatic decision | 0 | 0",
              ],
              [
                "Auto-review",
                "Allowed | 0 | 1",
                "Refused | 0 | 1",
                "No automatic decision | 0 | 0",
              ],
            ],
          },
        );
        writeFileSync("permission-contracts-ok", "");
      } finally {
        await session.extensionRunner.emit({
          type: "session_shutdown",
          reason: "quit",
        });
        session.dispose();
        await rm(cwd, { recursive: true, force: true });
      }
    },
  });
}
