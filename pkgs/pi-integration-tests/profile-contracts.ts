import { exportedFunction, parseRecord, isRecord } from "./protocol.js";
import assert from "node:assert/strict";
import {
  lstatSync,
  readFileSync,
  readdirSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import {
  loadSkills,
  type ExtensionAPI,
  type ExtensionCommandContext,
} from "@earendil-works/pi-coding-agent";

function requiredEnvironment(key: string): string {
  const value = process.env[key];
  assert.ok(
    value !== undefined && value !== "",
    `Expected ${key} for the profile fixture`,
  );
  return value;
}

function registerLifecycle(pi: ExtensionAPI): void {
  pi.registerCommand("dotfiles-profile-lifecycle", {
    handler: async (_args, ctx) => {
      let path: string | undefined;
      let entry: string | undefined;
      let fresh: ExtensionCommandContext | undefined;
      let forked: ExtensionCommandContext | undefined;
      let resumed: ExtensionCommandContext | undefined;
      const created = await ctx.newSession({
        setup: (manager) => {
          manager.appendMessage({
            role: "user",
            content: "Seeded question.",
            timestamp: Date.now(),
          });
          entry = manager.appendMessage({
            role: "assistant",
            api: "openai-completions",
            provider: "fixture",
            model: "gpt-test",
            content: [{ type: "text", text: "Seeded reply." }],
            stopReason: "stop",
            timestamp: Date.now(),
            usage: {
              input: 0,
              output: 0,
              cacheRead: 0,
              cacheWrite: 0,
              totalTokens: 0,
              cost: {
                input: 0,
                output: 0,
                cacheRead: 0,
                cacheWrite: 0,
                total: 0,
              },
            },
          });
          path = manager.getSessionFile();
          return Promise.resolve();
        },
        withSession: (next) => {
          fresh = next;
          return Promise.resolve();
        },
      });
      assert.deepStrictEqual(created, { cancelled: false });
      assert.ok(
        fresh !== undefined && path !== undefined && entry !== undefined,
      );
      const sessions = requiredEnvironment("PI_CODING_AGENT_SESSION_DIR");
      assert.ok(path.startsWith(sessions));
      assert.ok(statSync(path).isFile());
      const originalId = fresh.sessionManager.getSessionId();
      assert.deepStrictEqual(
        await fresh.fork(entry, {
          position: "at",
          withSession: (next) => {
            forked = next;
            return Promise.resolve();
          },
        }),
        { cancelled: false },
      );
      assert.ok(forked !== undefined);
      assert.notEqual(forked.sessionManager.getSessionId(), originalId);
      assert.deepStrictEqual(
        await forked.switchSession(path, {
          withSession: (next) => {
            resumed = next;
            return Promise.resolve();
          },
        }),
        { cancelled: false },
      );
      assert.ok(resumed !== undefined);
      assert.equal(resumed.sessionManager.getSessionFile(), path);
      await resumed.reload();
      writeFileSync("lifecycle-probe-ok", path);
    },
  });
}

interface ProfilePaths {
  agent: string;
  sessions: string;
  xdg: string;
  lens: string;
}

async function assertResources(
  pi: ExtensionAPI,
  paths: ProfilePaths,
  cwd: string,
): Promise<void> {
  const { agent, xdg, lens } = paths;
  const skills = loadSkills({
    cwd,
    agentDir: agent,
    includeDefaults: true,
    skillPaths: [join(homedir(), ".agents/skills")],
  });
  assert.deepStrictEqual(
    skills.diagnostics.filter((diagnostic) => diagnostic.type === "collision"),
    [],
  );
  assert.ok(skills.skills.some((skill) => skill.name === "gh-stack"));
  for (const collection of [
    "managed-extensions",
    "packages",
    "prompts",
    "themes",
    "skills",
  ]) {
    assert.ok(lstatSync(join(agent, collection)).isSymbolicLink(), collection);
  }
  assert.deepStrictEqual(
    readdirSync(join(agent, "managed-extensions")).toSorted(),
    ["planning", "prose-lint", "session-footer"],
  );
  assert.equal(lstatSync(join(agent, "extensions")).isSymbolicLink(), false);
  const permission = join(agent, "extensions/pi-permission-system/config.json");
  assert.deepStrictEqual(parseRecord(readFileSync(permission, "utf8")), {
    authorizerChain: ["auto-review"],
    permission: { "*": "allow", bash: "ask" },
  });
  assert.notEqual(statSync(permission).mode & 0o200, 0);
  assert.deepStrictEqual(readdirSync(join(agent, "themes")).toSorted(), [
    "catppuccin-frappe.json",
    "catppuccin-latte.json",
    "catppuccin-macchiato.json",
    "catppuccin-mocha.json",
  ]);
  assert.deepStrictEqual(
    ["footer", "pr", "ultrafast"].map((name) => ({
      name,
      count: pi.getCommands().filter((command) => command.name === name).length,
    })),
    [
      { name: "footer", count: 1 },
      { name: "pr", count: 1 },
      { name: "ultrafast", count: 1 },
    ],
  );
  assert.equal(process.env.PRETTY_CONFIG_DIR, agent);
  assert.deepStrictEqual(parseRecord(readFileSync(lens, "utf8")).widget, {
    visible: false,
  });
  assert.deepStrictEqual(
    parseRecord(readFileSync(join(xdg, "rpiv-todo/config.json"), "utf8")),
    { widget: { enabled: false } },
  );
  assert.deepStrictEqual(
    parseRecord(readFileSync(join(xdg, "rpiv-btw/config.json"), "utf8")),
    { crossSessionHint: false },
  );
  const config = join(agent, "extensions/subagent/config.json");
  assert.equal(
    parseRecord(readFileSync(config, "utf8")).defaultSessionDir,
    undefined,
  );
  assert.equal(statSync(config).mode & 0o222, 0);
  const helpers = ["git", "gh", "gh-stack", "prose-lint", "vale", "vale-ls"];
  const results = await Promise.all(
    helpers.map(async (name) => {
      const result = await pi.exec("bash", [
        "-c",
        'command -v "$1"',
        "fixture",
        name,
      ]);
      return { name, code: result.code, stderr: result.stderr };
    }),
  );
  assert.deepStrictEqual(
    results,
    helpers.map((name) => ({ name, code: 0, stderr: "" })),
  );
}

export default function profileContracts(
  pi: ExtensionAPI,
  createFactory: () => unknown,
): void {
  registerLifecycle(pi);
  pi.on("session_start", (_event, ctx) => {
    if (process.stdin.isTTY) {
      ctx.ui.setEditorText("profile-fixture-ready");
    }
  });
  pi.on("agent_start", () => {
    writeFileSync("unexpected-model-turn", "");
  });
  pi.registerCommand("dotfiles-profile-check", {
    handler: async (_args, ctx) => {
      const paths: ProfilePaths = {
        agent: requiredEnvironment("PI_CODING_AGENT_DIR"),
        sessions: requiredEnvironment("PI_CODING_AGENT_SESSION_DIR"),
        xdg: requiredEnvironment("XDG_CONFIG_HOME"),
        lens: requiredEnvironment("PI_LENS_CONFIG_PATH"),
      };
      const { agent, sessions } = paths;
      await assertResources(pi, paths, ctx.cwd);
      const factory = createFactory();
      assert.ok(isRecord(factory));
      const errors: unknown[] = [];
      const starts: string[] = [];
      const launch = {
        cwd: ctx.cwd,
        storage: { kind: "default" },
        model: "fixture/gpt-test",
        tools: ["read"],
        extensionPaths: [],
        ambientExtensions: true,
        noSkills: false,
        noContextFiles: false,
        processEnv: { PI_SUBAGENT_CHILD: "1" },
        restoreProcessEnv: true,
        runtime: {
          fanoutChild: false,
          depth: 1,
          fast: false,
          waitTool: { enabled: false },
        },
        hooks: [
          {
            name: "profile-probe",
            factory(api: ExtensionAPI) {
              api.on("session_start", (_event, childContext) => {
                assert.ok(
                  childContext
                    .getSystemPrompt()
                    .includes("Pi profile fixture instructions."),
                );
                assert.ok(childContext.getSystemPrompt().includes("gh-stack"));
                starts.push(childContext.sessionManager.getSessionId());
              });
            },
          },
        ],
        onExtensionError(error: unknown) {
          errors.push(error);
        },
      };
      let detached: Record<string, unknown> | undefined;
      try {
        const foreground: unknown = await exportedFunction(
          factory,
          "create",
        )(launch);
        assert.ok(isRecord(foreground));
        const detachedChild: unknown = await exportedFunction(
          factory,
          "create",
        )(launch);
        assert.ok(isRecord(detachedChild));
        detached = detachedChild;
        detached.detached = true;
        for (const child of [foreground, detached]) {
          assert.equal(typeof child.sessionFile, "string");
          assert.ok(
            typeof child.sessionFile === "string" &&
              child.sessionFile.startsWith(sessions),
          );
        }
        await exportedFunction(factory, "dispose")();
        assert.deepStrictEqual(
          [foreground.shutDown, detached.shutDown],
          [true, undefined],
        );
        assert.deepStrictEqual(errors, []);
        assert.equal(new Set(starts).size, 2);
        writeFileSync("profile-probe-ok", agent);
      } finally {
        if (detached !== undefined) {
          await exportedFunction(detached, "dispose")();
        }
        await exportedFunction(factory, "dispose")();
      }
    },
  });
}
