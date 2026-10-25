import { randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { expect, it, vi } from "vitest";
import { visibleWidth } from "@earendil-works/pi-tui";
import { PiTerminal } from "./tui/terminal.ts";

async function seed(
  root: string,
  cwd: string,
  quiet: boolean,
): Promise<string> {
  const timestamp = new Date().toISOString();
  const tasks = Array.from({ length: 24 }, (_, index) => ({
    id: index + 1,
    subject: index === 23 ? "Verify layout" : `Task ${index + 1}`,
    status: !quiet && index === 23 ? "in_progress" : "completed",
    blockedBy: [],
  }));
  const records = [
    { type: "session", version: 3, id: randomUUID(), timestamp, cwd },
    {
      type: "message",
      id: "a",
      parentId: null,
      timestamp,
      message: {
        role: "toolResult",
        toolCallId: "fixture",
        toolName: "todo",
        isError: false,
        timestamp: Date.now(),
        content: [{ type: "text", text: "Synthetic footer tasks" }],
        details: { tasks, nextId: 25 },
      },
    },
    {
      type: "message",
      id: "b",
      parentId: "a",
      timestamp,
      message: {
        role: "assistant",
        content: [{ type: "text", text: "Footer fixture. No model requests." }],
        api: "openai-codex-responses",
        provider: "openai-codex",
        model: "gpt-5.4",
        stopReason: "stop",
        timestamp: Date.now(),
        usage: {
          input: 18_000,
          output: 320,
          cacheRead: 82_000,
          cacheWrite: 0,
          totalTokens: 100_320,
          cost: {
            input: 0.01,
            output: 0.01,
            cacheRead: 0.02,
            cacheWrite: 0,
            total: 0.04,
          },
        },
      },
    },
  ];
  const session = join(root, "session.jsonl");

  await writeFile(
    session,
    records.map((entry) => JSON.stringify(entry) + "\n").join(""),
  );

  return session;
}

async function footer(terminal: PiTerminal, width: number): Promise<string[]> {
  let lines: string[] = [];

  await vi.waitFor(
    async () => {
      lines = (await terminal.screen()).slice(-2);

      expect(lines[0]).toContain("ctx 20.1%/500k");
      expect(lines[0]).toContain(" footer-fixture");
      expect(lines[1]).toContain("5h 40% used");
      expect(lines[1]).toContain(
        width >= 120 ? "week 42% used" : "5h 40% used",
      );
      expect(lines.join("\n")).not.toContain("unavailable");
      expect(lines.map((line) => visibleWidth(line))).toStrictEqual([
        width,
        width,
      ]);
    },
    { timeout: 10_000, interval: 25 },
  );

  return lines;
}

async function restored(
  terminal: PiTerminal,
  expected: string[],
): Promise<void> {
  await vi.waitFor(
    async () => {
      expect((await terminal.screen()).slice(-2)).toStrictEqual(expected);
    },
    { timeout: 5000, interval: 25 },
  );
}

it.each([
  { theme: "dark", quiet: false },
  { theme: "dark", quiet: true },
  { theme: "light", quiet: false },
  { theme: "light", quiet: true },
])(
  "runs real Pi with $theme theme and quiet=$quiet through theme changes, resizing and inspection",
  async ({ theme, quiet }) => {
    const root = await mkdtemp(join(tmpdir(), "pi-footer-tui-"));
    const work = join(root, "work");
    const agent = join(root, "agent");
    let terminal: PiTerminal | undefined;

    try {
      await mkdir(work);
      await mkdir(agent);
      execFileSync("git", ["init", "-b", "footer-fixture", work], {
        stdio: "ignore",
      });
      await writeFile(
        join(agent, "settings.json"),
        JSON.stringify({ quietStartup: "all", theme }),
      );

      const session = await seed(root, work, quiet);
      const networkLog = join(root, "network.log");
      const modelLog = join(root, "model.log");
      const updateLog = join(root, "updates.log");

      terminal = new PiTerminal({
        command: [
          process.execPath,
          "--import",
          fileURLToPath(new URL("./tui/network.mjs", import.meta.url)),
          fileURLToPath(
            new URL(
              "./bundle/cli.js",
              import.meta.resolve("@earendil-works/pi-coding-agent"),
            ),
          ),
          "--offline",
          "--no-extensions",
          "--no-skills",
          "--no-mcp",
          "--no-context-files",
          "--no-prompt-templates",
          "--no-approve",
          "--no-tools",
          "--provider",
          "openai-codex",
          "--model",
          "gpt-5.4",
          "--thinking",
          "high",
          "--session",
          session,
          "--use-theme",
          theme,
          "-e",
          fileURLToPath(new URL("../index.ts", import.meta.url)),
          "-e",
          fileURLToPath(new URL("./tui/fixture.ts", import.meta.url)),
        ],
        cwd: work,
        columns: 220,
        rows: 24,
        env: {
          PATH: process.env.PATH ?? "",
          HOME: root,
          TMPDIR: root,
          XDG_CONFIG_HOME: join(root, "config"),
          TERM: "xterm-256color",
          COLORTERM: "truecolor",
          PI_CODING_AGENT_DIR: agent,
          PI_OFFLINE: "1",
          PI_SKIP_VERSION_CHECK: "1",
          PI_FOOTER_QUIET: quiet ? "1" : "0",
          PI_FOOTER_NETWORK_LOG: networkLog,
          PI_FOOTER_MODEL_LOG: modelLog,
          PI_FOOTER_UPDATE_LOG: updateLog,
        },
      });

      const wide = await footer(terminal, 220);

      expect(terminal.color()).toBeDefined();

      await vi.waitFor(
        async () => {
          expect(
            Number(await readFile(updateLog, "utf8")),
          ).toBeGreaterThanOrEqual(3);
        },
        { timeout: 5000 },
      );

      await restored(terminal, wide);

      const originalColor = terminal.color("gpt-5.4");

      expect(originalColor).toBeDefined();
      expect(originalColor).not.toBe(terminal.color("codex/"));
      expect(terminal.color("40%")).not.toBe(terminal.color("5h "));
      expect({
        model: terminal.style("gpt-5.4")?.bold,
        directory: terminal.style("~/work")?.bold,
        provider: terminal.style("codex/")?.bold,
        quota: terminal.style("40%")?.bold,
        cost: terminal.style("$0.04")?.bold,
      }).toStrictEqual({
        model: true,
        directory: true,
        provider: false,
        quota: false,
        cost: false,
      });

      terminal.input(`/fixture-theme ${theme === "dark" ? "light" : "dark"}\r`);

      await vi.waitFor(
        async () => {
          expect((await terminal?.screen())?.slice(-2)).toStrictEqual(wide);
          expect(terminal?.color("gpt-5.4")).not.toBe(originalColor);
        },
        { timeout: 5000 },
      );

      terminal.input(`/fixture-theme ${theme}\r`);

      await vi.waitFor(
        async () => {
          expect((await terminal?.screen())?.slice(-2)).toStrictEqual(wide);
          expect(terminal?.color("gpt-5.4")).toBe(originalColor);
        },
        { timeout: 5000 },
      );

      terminal.resize(72);

      const narrow = await footer(terminal, 72);

      expect(narrow[1]).toMatch(
        quiet ? /^ + 5h/ : /^(?!.*1h59m).*1E 1W.*runs failed 1.*CI 1 failed/,
      );

      terminal.resize(220);

      await restored(terminal, wide);

      terminal.input("/footer quota\r");

      await vi.waitFor(
        async () => {
          expect((await terminal?.screen())?.join("\n")).toContain(
            "Footer: quota",
          );
        },
        { timeout: 5000 },
      );

      terminal.input("\u001B");

      await restored(terminal, wide);

      terminal.input("/footer workflow\r");

      await vi.waitFor(
        async () => {
          expect((await terminal?.screen())?.join("\n")).toContain(
            "#1 [completed] Task 1",
          );
        },
        { timeout: 5000 },
      );

      terminal.input("\u001B[6~");

      await vi.waitFor(
        async () => {
          expect((await terminal?.screen())?.join("\n")).not.toContain(
            "#1 [completed] Task 1",
          );
        },
        { timeout: 5000 },
      );

      terminal.input("\u001B[6~");

      await vi.waitFor(
        async () => {
          expect((await terminal?.screen())?.join("\n")).toContain(
            "Use /todos and /subagents",
          );
        },
        { timeout: 5000 },
      );

      terminal.input("\u001B");

      await restored(terminal, wide);
      expect({
        network: existsSync(networkLog),
        model: existsSync(modelLog),
      }).toStrictEqual({ network: false, model: false });
    } catch (error) {
      throw new Error(
        `${theme}/${quiet}\n${(await terminal?.screen())?.join("\n")}\n${terminal?.diagnostics()}`,
        { cause: error },
      );
    } finally {
      await terminal?.close();
      await rm(root, { recursive: true, force: true });
    }
  },
  30_000,
);
