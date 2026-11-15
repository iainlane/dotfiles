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
  type FauxProviderHandle,
  type FauxResponseFactory,
  type Provider,
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

// A copy of answerEveryRequest in pi-planning's test/fixtures/faux.ts. Each
// package builds from its own directory, so the two cannot share a file.
function answerEveryRequest(
  faux: FauxProviderHandle,
  respond: FauxResponseFactory,
): Provider {
  // The faux provider takes the next queued step as soon as a request starts.
  // Queueing `respond` at that point gives every request one step, however
  // many requests start together.
  return {
    ...faux.provider,
    stream: (model, context, options) => {
      faux.appendResponses([respond]);
      return faux.provider.stream(model, context, options);
    },
    streamSimple: (model, context, options) => {
      faux.appendResponses([respond]);
      return faux.provider.streamSimple(model, context, options);
    },
  };
}

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
      const mainProvider = answerEveryRequest(main, ({ messages }) => {
        const last = messages.at(-1);
        if (last?.role !== "user") {
          return fauxAssistantMessage(fauxText("Done."));
        }
        const outcome = JSON.stringify(last.content).includes("denied")
          ? "deny"
          : "allow";
        return fauxAssistantMessage(
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
        );
      });
      const investigationTools = new Set<string>();
      const reviewerProvider = answerEveryRequest(reviewer, ({ messages }) => {
        for (const tool of getCurrentTools(messages)) {
          investigationTools.add(tool.name);
        }
        const request = JSON.stringify(
          messages.findLast((message) => message.role === "user")?.content,
        );
        const outcome =
          request.includes("shell-allow.txt") &&
          !request.includes("shell-deny.txt")
            ? "allow"
            : "deny";
        return fauxAssistantMessage(
          fauxText(JSON.stringify({ outcome, rationale: "Fixture verdict." })),
        );
      });
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
      for (const provider of [mainProvider, reviewerProvider]) {
        modelRuntime.registerNativeProvider(provider);
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
      const toolResults = () =>
        session.messages
          .filter((message) => message.role === "toolResult")
          .map(({ toolCallId, isError }) => ({ toolCallId, isError }));
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
        await session.prompt("/auto-stats", { source: "rpc" });
        await session.waitForIdle();
        assert.deepStrictEqual(
          {
            errors,
            loadErrors: initial.extensionsResult.errors,
            investigationTools: [...investigationTools],
            files: {
              allowed: readFileSync(join(cwd, "shell-allow.txt"), "utf8"),
              denied: existsSync(join(cwd, "shell-deny.txt")),
              direct: outcomes.map((outcome) =>
                readFileSync(join(cwd, `direct-${outcome}.txt`), "utf8"),
              ),
            },
            results: toolResults(),
          },
          {
            errors: [],
            loadErrors: [],
            investigationTools: [],
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
            results: toolResults(),
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
            results: [],
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
