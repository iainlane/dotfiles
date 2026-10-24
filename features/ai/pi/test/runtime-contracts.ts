import { exportedFunction, isRecord } from "./protocol.js";
import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import {
  createReadTool,
  type ExtensionAPI,
  type ExtensionContext,
  type ExtensionCommandContext,
  type ExtensionToolContext,
  type ToolDefinition,
} from "@earendil-works/pi-coding-agent";
import { stripTerminalSequences } from "@earendil-works/pi-tui";

export default function contracts(pi: ExtensionAPI): void {
  pi.registerCommand("dotfiles-runtime-contracts", {
    handler: async (_args, ctx) => {
      const root = await mkdtemp(join(tmpdir(), "pi-contracts-"));
      try {
        const hooks = new Map<
          string,
          (event: unknown, context: ExtensionContext) => unknown
        >();
        const notify: unknown = await import(
          pathToFileURL(`${process.env.PI_NOTIFY_ROOT}/index.ts`).href
        );
        exportedFunction(
          notify,
          "default",
        )({
          on: (
            event: string,
            callback: (event: unknown, context: ExtensionContext) => unknown,
          ) => hooks.set(event, callback),
        });
        assert.ok(!hooks.has("agent_end"));
        const settled = hooks.get("agent_settled");
        assert.ok(settled);
        const output: string[] = [];
        const original = Object.getOwnPropertyDescriptor(
          process.stdout,
          "write",
        );
        for (const key of [
          "TMUX",
          "WT_SESSION",
          "ITERM_SESSION_ID",
          "KITTY_WINDOW_ID",
          "PI_NOTIFY_SOUND_CMD",
        ]) {
          delete process.env[key];
        }
        process.env.TERM_PROGRAM = "fixture";
        process.stdout.write = (chunk) => {
          output.push(String(chunk));
          return true;
        };
        try {
          await Promise.all(
            (["rpc", "json", "print"] as const).map((mode) =>
              settled({}, { ...ctx, mode }),
            ),
          );
          assert.deepStrictEqual(output, []);
          await settled({}, { ...ctx, mode: "tui" });
          assert.deepStrictEqual(output, [
            "\u001B]777;notify;Pi;Ready for input\u0007",
          ]);
        } finally {
          if (original) {
            Object.defineProperty(process.stdout, "write", original);
          } else {
            Reflect.deleteProperty(process.stdout, "write");
          }
        }

        const git = async (args: string[]) => {
          const result = await pi.exec("git", args, { cwd: root });
          assert.equal(result.code, 0, JSON.stringify({ args, ...result }));
        };
        await git(["init", "-b", "fixture"]);
        await writeFile(join(root, "file.ts"), "first\n");
        await git(["add", "file.ts"]);
        const commit = [
          "-c",
          "user.name=Fixture",
          "-c",
          "user.email=fixture@example.invalid",
          "commit",
          "--no-gpg-sign",
          "-m",
        ];
        await git([...commit, "first"]);
        await writeFile(join(root, "file.ts"), "second\n");
        await git(["add", "file.ts"]);
        await git([...commit, "second"]);
        const simplify: unknown = await import(
          pathToFileURL(`${process.env.PI_SIMPLIFY_ROOT}/src/index.ts`).href
        );
        let command:
          | ((args: string, context: ExtensionCommandContext) => Promise<void>)
          | undefined;
        const prompts: unknown[] = [];
        const notices: string[] = [];
        exportedFunction(
          simplify,
          "default",
        )({
          registerCommand: (
            _name: string,
            definition: { handler: typeof command },
          ) => {
            command = definition.handler;
          },
          exec: pi.exec.bind(pi),
          sendUserMessage: (prompt: unknown) => prompts.push(prompt),
        });
        assert.ok(command);
        const context: ExtensionCommandContext = {
          ...ctx,
          cwd: root,
          ui: { ...ctx.ui, notify: (message: string) => notices.push(message) },
        };
        await command("--staged", context);
        assert.deepStrictEqual(prompts, []);
        await command("--ref=missing-fixture-ref", context);
        assert.deepStrictEqual(prompts, []);
        assert.ok(
          notices.some((notice) =>
            notice.includes("Cannot inspect the selected Git changes"),
          ),
        );

        const pretty: unknown = await import(
          pathToFileURL(`${process.env.PI_PRETTY_ROOT}/src/tools/read.ts`).href
        );
        let read: ToolDefinition | undefined;
        const nativeRead = createReadTool(root);
        exportedFunction(pretty, "registerReadTool")(
          {
            registerTool: (tool: ToolDefinition) => {
              read = tool;
            },
          },
          root,
          undefined,
          nativeRead,
        );
        assert.ok(read);
        const readTool = read;
        const path = join(root, "lines.txt");
        await writeFile(path, "first\nsecond\nthird\n");
        const args = { path, offset: 2, limit: 1 };
        const toolContext: ExtensionToolContext = {
          ...ctx,
          tools: [],
          executeTool: async () => {
            throw new Error(
              "The read contract unexpectedly called another tool",
            );
          },
        };
        const result = await readTool.execute(
          "fixture",
          args,
          undefined,
          undefined,
          toolContext,
        );
        const component = readTool.renderResult?.(
          result,
          { expanded: true, isPartial: false },
          ctx.ui.theme,
          {
            args,
            expanded: true,
            state: {},
            toolCallId: "fixture",
            cwd: root,
            lastComponent: undefined,
            executionStarted: true,
            argsComplete: true,
            isPartial: false,
            showImages: false,
            isError: false,
            durationMs: undefined,
            outputPad: 1,
            invalidate() {},
          },
        );
        assert.ok(component);
        await new Promise<void>((resolve) => {
          setTimeout(resolve, 50);
        });
        const lines = component
          .render(120)
          .map((line) => stripTerminalSequences(line));
        assert.ok(
          lines.some((line) => /2\s+│\s+second/.test(line)),
          JSON.stringify(lines),
        );
        assert.ok(
          !lines.some((line) =>
            /│.*(?:more lines in file|Use offset=)/.test(line),
          ),
          JSON.stringify(lines),
        );
        const literal =
          "alpha\n\n[Showing lines 1-2 of 9. Use offset=3 to continue.]";
        const reads = [
          {
            id: "zero",
            content: "first\nsecond\nthird\nfourth",
            args: { limit: 0 },
            expected: {
              content: "",
              notice: "[4 more lines in file. Use offset=1 to continue.]",
            },
          },
          {
            id: "literal",
            content: literal,
            args: {},
            expected: { content: literal, notice: undefined },
          },
          {
            id: "crlf",
            content: "first\r\nsecond\r\nthird",
            args: { offset: 2, limit: 1 },
            expected: {
              content: "second",
              notice: "[1 more lines in file. Use offset=3 to continue.]",
            },
          },
        ];
        const observations = await Promise.all(
          reads.map(async (fixture) => {
            const fixturePath = join(root, fixture.id + ".txt");
            await writeFile(fixturePath, fixture.content);
            const value = await readTool.execute(
              fixture.id,
              { path: fixturePath, ...fixture.args },
              undefined,
              undefined,
              toolContext,
            );
            assert.ok(isRecord(value.details));
            return {
              id: fixture.id,
              content: value.details.content,
              notice: value.details.notice,
            };
          }),
        );
        assert.deepStrictEqual(
          observations,
          reads.map((fixture) => ({
            id: fixture.id,
            content: fixture.expected.content,
            notice: fixture.expected.notice,
          })),
        );
        await Promise.all(
          [-1, 1.5].map(async (limit) => {
            const fixturePath = join(root, `unusual-limit-${limit}.txt`);
            await writeFile(fixturePath, "first\nsecond\nthird");
            const unusualArgs = { path: fixturePath, limit };
            const [native, prettyResult] = await Promise.all([
              nativeRead.execute(
                "native-unusual",
                unusualArgs,
                undefined,
                undefined,
              ),
              readTool.execute(
                "pretty-unusual",
                unusualArgs,
                undefined,
                undefined,
                toolContext,
              ),
            ]);
            const text = native.content.find((part) => part.type === "text");
            assert.ok(text?.type === "text");
            assert.ok(isRecord(prettyResult.details));
            assert.deepStrictEqual(
              {
                content: prettyResult.details.content,
                notice: prettyResult.details.notice,
              },
              {
                content: text.text.replaceAll("\r\n", "\n"),
                notice: undefined,
              },
            );
          }),
        );
        await writeFile("runtime-contracts-ok", "");
      } finally {
        await rm(root, { recursive: true, force: true });
      }
    },
  });
}
