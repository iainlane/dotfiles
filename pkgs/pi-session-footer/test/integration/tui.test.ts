import { randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { expect, it, onTestFinished } from "vitest";
import { visibleWidth } from "@earendil-works/pi-tui";
import { sessionStarts } from "#test/support/session-starts.ts";
import { PiTerminal } from "#test/support/terminal.ts";

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
      id: "read-call",
      parentId: "a",
      timestamp,
      message: {
        role: "assistant",
        content: [
          {
            type: "toolCall",
            id: "fixture-read",
            name: "read",
            arguments: { path: "fixture.ts" },
          },
        ],
        api: "openai-responses",
        provider: "openai",
        model: "gpt-5.4",
        stopReason: "toolUse",
        timestamp: Date.now(),
        usage: {
          input: 0,
          output: 0,
          cacheRead: 0,
          cacheWrite: 0,
          totalTokens: 0,
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
        },
      },
    },
    {
      type: "message",
      id: "read-result",
      parentId: "read-call",
      timestamp,
      message: {
        role: "toolResult",
        toolCallId: "fixture-read",
        toolName: "read",
        content: [{ type: "text", text: "export const fixture = true;" }],
        details: {
          _type: "readFile",
          filePath: "fixture.ts",
          content: "export const fixture = true;",
          offset: 1,
          lineCount: 1,
        },
        isError: false,
        timestamp: Date.now(),
      },
    },
    {
      type: "message",
      id: "b",
      parentId: "read-result",
      timestamp,
      message: {
        role: "assistant",
        content: [{ type: "text", text: "Footer fixture. No model requests." }],
        api: "openai-responses",
        provider: "openai",
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

function editorRows(screen: string[]): string {
  const top = screen.findLastIndex((line) => line.startsWith("╭─ "));
  const bottom = screen.findLastIndex((line) => line.startsWith("╰─ "));
  return screen.slice(top + 1, bottom + 1).join("\n");
}

function composerStatusRows(screen: string[], compact: boolean): string[] {
  return [
    screen.findLast((line) => line.startsWith("╭─ ")) ?? "",
    compact ? "" : (screen.findLast((line) => line.startsWith("╰─ ")) ?? ""),
  ];
}

async function footer(
  terminal: PiTerminal,
  width: number,
  quiet: boolean,
): Promise<string[]> {
  let lines: string[] = [];

  await terminal.until((screen) => {
    lines = composerStatusRows(screen, quiet);

    expect(lines[0]).toMatch(/^╭─ /);
    const top = screen.findLastIndex((line) => line.startsWith("╭─ "));
    expect(screen[top + 1]).toMatch(quiet ? /^╰─ .*─╯$/ : /^│.*│$/);
    expect(screen.slice(top + (quiet ? 2 : 3)).join("\n")).not.toMatch(
      /gpt-5\.4|◫ |◴ 5h 40%/,
    );

    expect(lines[0]).toContain("◫ 36.9%/272k");
    expect(lines[0]).toContain(" footer-fixture");
    expect({
      quotaWindows: /◴ 5h 40%.*◴ week 42%/.test(lines[1] ?? ""),
      planning: lines[1]?.includes("≡") ?? false,
    }).toStrictEqual({
      quotaWindows: !quiet,
      planning: !quiet,
    });
    expect(lines.join("\n")).not.toMatch(/status \+\d/);
    expect(lines.join("\n")).not.toContain("FFF indexed");
    expect(lines.join("\n")).not.toContain("unavailable");
    expect(lines.map((line) => visibleWidth(line))).toStrictEqual([
      width,
      quiet ? 0 : width,
    ]);
  });

  return lines;
}

async function restored(
  terminal: PiTerminal,
  expected: string[],
): Promise<void> {
  await terminal.until((screen) => {
    expect(screen.join("\n")).not.toContain("Footer:");
    expect(screen.join("\n")).not.toContain("Footer ›");
    expect(composerStatusRows(screen, expected[1] === "")).toStrictEqual(
      expected,
    );
  });
}

it.each([
  { theme: "dark", quiet: false, prettyFirst: true, mode: "fullscreen" },
  { theme: "dark", quiet: true, prettyFirst: false, mode: "regular" },
  { theme: "light", quiet: false, prettyFirst: false, mode: "fullscreen" },
  { theme: "light", quiet: true, prettyFirst: true, mode: "regular" },
  { theme: "dark", quiet: true, prettyFirst: true, mode: "fullscreen" },
  { theme: "dark", quiet: false, prettyFirst: false, mode: "regular" },
  { theme: "light", quiet: true, prettyFirst: false, mode: "fullscreen" },
  { theme: "light", quiet: false, prettyFirst: true, mode: "regular" },
])(
  "runs real Pi in $mode mode with $theme theme, quiet=$quiet and Pretty first=$prettyFirst",
  async ({ theme, quiet, prettyFirst, mode }) => {
    const statusRows = (screen: string[]) => composerStatusRows(screen, quiet);
    const pretty = process.env.PI_TEST_PRETTY;

    if (pretty === undefined || pretty === "") {
      throw new Error(
        "Set PI_TEST_PRETTY to the installed pi-pretty package root.",
      );
    }
    const root = await mkdtemp(join(tmpdir(), "pi-footer-tui-"));
    onTestFinished(() => rm(root, { recursive: true, force: true }));
    const work = join(root, "work");
    const agent = join(root, "agent");

    await mkdir(work);
    await mkdir(agent);
    execFileSync("git", ["init", "-b", "footer-fixture", work], {
      stdio: "ignore",
    });
    await writeFile(
      join(agent, "settings.json"),
      JSON.stringify({ quietStartup: "all", theme }),
    );

    const footerConfig = JSON.stringify({
      preset: quiet ? "compact" : "rich",
    });
    await writeFile(join(agent, "session-footer.json"), footerConfig);
    await writeFile(
      join(agent, "pi-pretty.json"),
      JSON.stringify({
        toolStyle: "claudecode",
        disableTools: ["find", "grep"],
        workingIndicator: { enabled: false },
        thinkingIndicator: { enabled: false },
      }),
    );

    const session = await seed(root, work, quiet);
    const networkLog = join(root, "network.log");
    const modelLog = join(root, "model.log");
    const updateLog = join(root, "updates.log");
    const startLog = join(root, "starts.log");

    const terminal = new PiTerminal({
      command: [
        ...(process.env.PI_TEST_HOST !== undefined &&
        process.env.PI_TEST_HOST !== ""
          ? [process.env.PI_TEST_HOST]
          : [
              process.execPath,
              "--import",
              fileURLToPath(
                new URL(import.meta.resolve("#test/support/network.ts")),
              ),
              fileURLToPath(
                new URL(
                  "./bundle/cli.js",
                  import.meta.resolve("@earendil-works/pi-coding-agent"),
                ),
              ),
            ]),
        "--offline",
        "--tui-mode",
        mode,
        "--no-extensions",
        "--no-skills",
        "--no-mcp",
        "--no-context-files",
        "--no-prompt-templates",
        "--no-approve",
        "--tools",
        "read",
        "--provider",
        "openai",
        "--model",
        "gpt-5.4",
        "--thinking",
        "high",
        "--session",
        session,
        "--use-theme",
        theme,
        ...(prettyFirst
          ? [
              "-e",
              pretty,
              "-e",
              fileURLToPath(new URL(import.meta.resolve("#footer-entry"))),
            ]
          : [
              "-e",
              fileURLToPath(new URL(import.meta.resolve("#footer-entry"))),
              "-e",
              pretty,
            ]),
        "-e",
        fileURLToPath(
          new URL(import.meta.resolve("#test/fixtures/session.ts")),
        ),
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
        PRETTY_CONFIG_DIR: agent,
        ...(process.env.PI_TEST_HOST !== undefined &&
        process.env.PI_TEST_HOST !== ""
          ? {
              NODE_OPTIONS: `--import=${fileURLToPath(new URL(import.meta.resolve("#test/support/network.ts")))}`,
            }
          : {}),
        PI_OFFLINE: "1",
        PI_SKIP_VERSION_CHECK: "1",
        PI_FOOTER_QUIET: quiet ? "1" : "0",
        PI_FOOTER_NETWORK_LOG: networkLog,
        PI_FOOTER_MODEL_LOG: modelLog,
        PI_FOOTER_UPDATE_LOG: updateLog,
        PI_FOOTER_START_LOG: startLog,
        PI_FOOTER_SESSION: session,
      },
    });

    await terminal.until(async () => {
      expect(Number(await readFile(updateLog, "utf8"))).toBeGreaterThanOrEqual(
        1,
      );
    }, [updateLog]);

    const wide = await footer(terminal, 220, quiet);
    await terminal.until((screen) => {
      expect(screen.join("\n")).toContain("Read (fixture.ts)");
    });

    expect(terminal.color()).toBeDefined();

    const published = Number(await readFile(updateLog, "utf8"));
    terminal.input("/fixture-publish\r");
    terminal.input("/fixture-publish\r");
    await terminal.until(async () => {
      expect(Number(await readFile(updateLog, "utf8"))).toBeGreaterThanOrEqual(
        published + 2,
      );
    }, [updateLog]);

    await restored(terminal, wide);

    const history = `/fixture-theme ${theme}`;
    terminal.input(`${history}\r`);
    await restored(terminal, wide);
    terminal.input("\u001B[A");
    await terminal.until((screen) => {
      expect(editorRows(screen)).toContain(history);
    });
    terminal.input("\u0005");
    terminal.input("\u0015");
    await terminal.until((screen) => {
      expect(editorRows(screen)).not.toContain(history);
    });

    terminal.input("/footer he");
    await terminal.until((screen) => {
      expect(screen.join("\n")).toContain(
        "Commands, widget catalogue and navigation",
      );
    });
    terminal.input("\t");
    await terminal.until((screen) => {
      expect(editorRows(screen)).toContain("/footer help");
    });
    terminal.input("\u0015");
    await terminal.until((screen) => {
      expect(editorRows(screen)).not.toContain("/footer");
    });

    terminal.input("/footer c");
    let row = -1;
    await terminal.until((screen) => {
      row = screen.findLastIndex((line) =>
        line.includes("Preview and customise the footer"),
      );
      expect(row).toBeGreaterThanOrEqual(0);
    });
    terminal.input(
      mode === "fullscreen"
        ? `\u001B[<0;8;${row + 1}M\u001B[<0;8;${row + 1}m`
        : "\t",
    );
    await terminal.until((screen) => {
      expect(editorRows(screen)).toContain("/footer config");
    });
    terminal.input("\u0015");
    await terminal.until((screen) => {
      expect(editorRows(screen)).not.toContain("/footer");
    });

    terminal.input("/fixture-overflow\r");
    await terminal.until((screen) => {
      expect(statusRows(screen)[0]).toMatch(/↑ \d+ more/);
      expect(editorRows(screen)).toContain("overflow 29");
    });
    terminal.input("\u0003");
    await terminal.until((screen) => {
      expect(editorRows(screen)).not.toContain("overflow");
    });
    await restored(terminal, wide);

    const originalColor = terminal.color("gpt-5.4");

    expect(originalColor).toBeDefined();
    expect(originalColor).not.toBe(terminal.color("openai/"));
    expect(terminal.color(quiet ? "36.9%" : "40%")).not.toBe(
      terminal.color(quiet ? "◫ " : "◴ 5h "),
    );
    expect({
      model: terminal.style("gpt-5.4")?.bold,
      directory: terminal.style("~/work")?.bold,
      provider: terminal.style("openai/")?.bold,
      quota: terminal.style("40%")?.bold,
      cost: terminal.style("$0.04")?.bold,
    }).toStrictEqual({
      model: true,
      directory: true,
      provider: false,
      quota: quiet ? undefined : false,
      cost: quiet ? undefined : false,
    });

    terminal.input(`/fixture-theme ${theme === "dark" ? "light" : "dark"}\r`);

    await terminal.until((screen) => {
      expect(statusRows(screen)).toStrictEqual(wide);
      expect(terminal.color("gpt-5.4")).not.toBe(originalColor);
    });

    terminal.input(`/fixture-theme ${theme}\r`);

    await terminal.until((screen) => {
      expect(statusRows(screen)).toStrictEqual(wide);
      expect(terminal.color("gpt-5.4")).toBe(originalColor);
    });

    terminal.resize(72);

    const narrow = await footer(terminal, 72, quiet);

    expect({
      diagnostics: narrow[1]?.includes("⊗1 ⚠1"),
      failedRun: narrow[1]?.includes(" failed 1"),
      failedChecks: narrow[1]?.includes(" 1 failed"),
    }).toStrictEqual({
      diagnostics: !quiet,
      failedRun: !quiet,
      failedChecks: !quiet,
    });

    terminal.resize(220);

    await restored(terminal, wide);

    terminal.input("/footer explain quota\r");

    await terminal.until((screen) => {
      expect(screen.join("\n")).toContain("Footer › Explain › Quota");
      expect(screen.join("\n")).toContain("Rendering details");
    });
    terminal.input(quiet ? "\r" : "\u001B[B\r");
    await terminal.until((screen) => {
      expect(
        screen.find((line) => line.startsWith("Footer ›"))?.trimEnd(),
      ).toBe("Footer › Explain › Quota › Rendering details");
      expect(screen.join("\n")).toContain("Usable columns:");
    });
    terminal.input("\u001B");
    await terminal.until((screen) => {
      expect(
        screen.find((line) => line.startsWith("Footer ›"))?.trimEnd(),
      ).toBe("Footer › Explain › Quota");
      expect(screen.join("\n")).toContain("enter open");
    });

    terminal.input("\u001B");
    await terminal.until((screen) => {
      expect(screen.join("\n")).toContain("escape/ctrl+c close");
    });
    terminal.input("\u001B");

    await restored(terminal, wide);

    terminal.input("/footer\r");
    await terminal.until((screen) => {
      expect(screen.join("\n")).toContain("Footer › Explain");
    });
    terminal.input("\t\t\t");

    await terminal.until((screen) => {
      expect(screen.join("\n")).toContain("Task 1  Complete");
    });

    terminal.input("\u001B[6~");

    await terminal.until((screen) => {
      expect(screen.join("\n")).not.toContain("Task 1  Complete");
    });

    terminal.input("\u001B[6~");

    await terminal.until((screen) => {
      expect(screen.join("\n")).toContain("Task & agent details");
    });

    terminal.input("\u001B");

    await restored(terminal, wide);

    expect(await readFile(join(agent, "session-footer.json"), "utf8")).toBe(
      footerConfig,
    );
    terminal.input("/fixture-inspect\r");
    await terminal.until((screen) => {
      expect(screen.join("\n")).toContain("Footer › Explain");
    });
    terminal.input("\u001B");
    await terminal.until((screen) => {
      expect(screen.join("\n")).not.toContain("Footer ›");
      const top = screen.findLastIndex((line) => line.startsWith("╭─ "));
      expect(screen[top + 1]).toContain("draft 界é");
      expect(statusRows(screen)[0]).toBe(wide[0]);
    });
    terminal.input("\u0015");
    terminal.input("\u001B[200~first\nsecond 界é\u001B[201~");
    await terminal.until((screen) => {
      const top = screen.findLastIndex((line) => line.startsWith("╭─ "));
      expect(
        screen.slice(top + 1, top + 3).map((line) => line.trimEnd()),
      ).toStrictEqual([
        `│  first${" ".repeat(211)}│`,
        quiet
          ? `╰─ second 界é${" ".repeat(205)}─╯`
          : `│  second 界é${" ".repeat(206)}│`,
      ]);
    });
    // Pi exits on a second Ctrl+C within 500 ms of the previous one. Clear the
    // pasted lines without Ctrl+C so the result does not depend on the time
    // since the earlier Ctrl+C.
    terminal.input("\u0015\u007F\u0015");
    terminal.input("/fo");
    await terminal.until((screen) => {
      expect(screen.join("\n")).toContain("Inspect footer measurements");
    });
    terminal.input("\u001B");
    await terminal.until((screen) => {
      expect(screen.join("\n")).not.toContain("Inspect footer measurements");
    });
    terminal.input("\u0015");
    await terminal.until((screen) => {
      const top = screen.findLastIndex((line) => line.startsWith("╭─ "));
      expect(screen[top + 1]?.trim()).toMatch(quiet ? /^╰─ +─╯$/ : /^│ +│$/);
    });

    const border = terminal.color("╭─ ");
    terminal.input("!echo fixture");
    await terminal.until((screen) => {
      const top = screen.findLastIndex((line) => line.startsWith("╭─ "));
      expect(screen[top + 1]).toContain("!echo fixture");
      expect(terminal.color("╭─ ")).not.toBe(border);
    });
    terminal.input("\u0015");
    await terminal.until((screen) => {
      expect({
        frame:
          screen[screen.findLastIndex((line) => line.startsWith("╭─ ")) + 1],
        color: terminal.color("╭─ "),
      }).toStrictEqual({
        frame: quiet ? `╰─${" ".repeat(216)}─╯` : `│${" ".repeat(218)}│`,
        color: border,
      });
    });

    const starts = await sessionStarts(startLog);
    terminal.input("/reload");
    await terminal.until((screen) => {
      const top = screen.findLastIndex((line) => line.startsWith("╭─ "));
      expect(screen[top + 1]).toContain("/reload");
    });
    terminal.input("\r");
    await terminal.until(async () => {
      expect(await sessionStarts(startLog)).toBeGreaterThan(starts);
    }, [startLog]);
    await footer(terminal, 220, quiet);

    const reloaded = await sessionStarts(startLog);
    terminal.input("/new\r");
    await terminal.until(async () => {
      expect(await sessionStarts(startLog)).toBeGreaterThan(reloaded);
    }, [startLog]);
    await terminal.until((screen) => {
      expect(statusRows(screen)[0]).toContain("gpt-5.4");
      expect(screen.findLast((line) => line.startsWith("╰─ "))).toMatch(
        /^╰─ .*─╯$/,
      );
    });
    terminal.input("/fixture-resume\r");
    await footer(terminal, 220, quiet);

    terminal.input("/footer config\r");
    await terminal.until((screen) => {
      expect(screen.join("\n")).toContain("Footer › Customise");
    });
    terminal.input("\u001B");
    await restored(terminal, wide);
    expect(await readFile(join(agent, "session-footer.json"), "utf8")).toBe(
      footerConfig,
    );
    await writeFile(join(agent, "session-footer.json"), '{"preset":"invalid"}');
    terminal.input("/reload\r");
    await terminal.until((screen) => {
      expect(screen.join("\n")).toContain("Cannot load");
      expect(composerStatusRows(screen, false)[1]).toContain("◴ week 42%");
    });
    expect(await readFile(join(agent, "session-footer.json"), "utf8")).toBe(
      '{"preset":"invalid"}',
    );
    expect({
      network: existsSync(networkLog),
      model: existsSync(modelLog),
    }).toStrictEqual({ network: false, model: false });
  },
);
