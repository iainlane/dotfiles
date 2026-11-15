import { randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { expect, it, onTestFinished } from "vitest";
import { visibleWidth } from "@earendil-works/pi-tui";
import {
  clockStart,
  clockedFooter,
  fixtureClock,
} from "#test/support/fixture-clock.ts";
import { latestSessionStart } from "#test/support/session-starts.ts";
import { PiTerminal } from "#test/support/terminal.ts";

async function seed(
  root: string,
  cwd: string,
  quiet: boolean,
): Promise<string> {
  const timestamp = new Date(clockStart).toISOString();
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
        timestamp: clockStart,
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
        timestamp: clockStart,
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
        timestamp: clockStart,
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
        timestamp: clockStart,
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

/**
 * The composer's footer rows for each step, in the compact profile used when
 * the session is quiet and in the rich profile otherwise. The fixture clock
 * stays at `clockStart` until the `later` step moves it one minute on.
 */
const footerRows = {
  wide: {
    quiet: [
      "╭─  openai/gpt-5.4  ◒ high   ~/work   footer-fixture ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━──────────────────────────────────────────────────────────────────────────────────────────  ◫ 36.9%/272k ─╮",
      "",
    ],
    rich: [
      "╭─  openai/gpt-5.4  ◒ high   ~/work   footer-fixture   #123 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━─────────────────────────────────────────────────────────────────────────────────────  ◫ 36.9%/272k ─╮",
      "╰─ ⊗1 ⚠1  ☑ 23/24 Verify layout   2   failed 1  ≡   1 failed   2                                                                                       ◴ 5h 40% ↻2h  ◴ week 42% ↻2d   82.0%  ≈$0.04   0m ─╯",
    ],
  },
  narrow: {
    quiet: [
      "╭─  openai/gpt-5.4  ◒ high   footer-fixture ━━────  ◫ 36.9%/272k ─╮",
      "",
    ],
    rich: [
      "╭─  openai/gpt-5.4  ◒   footer-fixture   #123     ◫ 36.9%/272k ─╮",
      "╰─ ⊗1 ⚠1   failed 1  ≡   1 failed   2   ◴ 5h 40%  ◴ week 42% ─╯",
    ],
  },
  overflow: {
    quiet: [
      "╭─  openai/gpt-5.4  ◒ high   ~/work   footer-fixture ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━────────────────────────────────────────────────────────────────────────────────────  ◫ 36.9%/272k ↑ 23 more ─╮",
      "",
    ],
    rich: [
      "╭─  openai/gpt-5.4  ◒ high   ~/work   footer-fixture   #123 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━──────────────────────────────────────────────────────────────────────────────  ◫ 36.9%/272k ↑ 23 more ─╮",
      "╰─ ⊗1 ⚠1  ☑ 23/24 Verify layout   2   failed 1  ≡   1 failed   2                                                                                       ◴ 5h 40% ↻2h  ◴ week 42% ↻2d   82.0%  ≈$0.04   0m ─╯",
    ],
  },
  newSession: {
    quiet: [
      "╭─  openai/gpt-5.4  ◒ high   ~/work   footer-fixture ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────  ◫ 0.0%/272k ─╮",
      "╰─                                                                                                                                                                                                                        ─╯",
    ],
    rich: [
      "╭─  openai/gpt-5.4  ◒ high   ~/work   footer-fixture   #123 ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────  ◫ 0.0%/272k ─╮",
      "╰─ ⊗1 ⚠1   2   failed 1  ≡   1 failed   2                                                                                                                                         ◴ 5h 40% ↻2h  ◴ week 42% ↻2d ─╯",
    ],
  },
  later: {
    quiet: [
      "╭─  openai/gpt-5.4  ◒ high   ~/work   footer-fixture ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━──────────────────────────────────────────────────────────────────────────────────────────  ◫ 36.9%/272k ─╮",
      "╰─                                                                                                                                                         ◴ 5h 40% ↻1h59m  ◴ week 42% ↻1d23h   82.0%  ≈$0.04   1m ─╯",
    ],
    rich: [
      "╭─  openai/gpt-5.4  ◒ high   ~/work   footer-fixture   #123 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━─────────────────────────────────────────────────────────────────────────────────────  ◫ 36.9%/272k ─╮",
      "╰─ ⊗1 ⚠1  ☑ 23/24 Verify layout   2   failed 1  ≡   1 failed   2                                                                                 ◴ 5h 40% ↻1h59m  ◴ week 42% ↻1d23h   82.0%  ≈$0.04   1m ─╯",
    ],
  },
  fallback: {
    quiet: [
      "╭─  openai/gpt-5.4  ◒ high   ~/work   footer-fixture ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━──────────────────────────────────────────────────────────────────────────────────────────  ◫ 36.9%/272k ─╮",
      "╰─                                                                                                                                                               ◴ 5h 40% ↻2h  ◴ week 42% ↻2d   82.0%  ≈$0.04   0m ─╯",
    ],
    rich: [
      "╭─  openai/gpt-5.4  ◒ high   ~/work   footer-fixture   #123 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━─────────────────────────────────────────────────────────────────────────────────────  ◫ 36.9%/272k ─╮",
      "╰─ ⊗1 ⚠1  ☑ 23/24 Verify layout   2   failed 1  ≡   1 failed   2                                                                                       ◴ 5h 40% ↻2h  ◴ week 42% ↻2d   82.0%  ≈$0.04   0m ─╯",
    ],
  },
};

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

function composerTop(screen: string[]): string {
  return screen.findLast((line) => line.startsWith("╭─ ")) ?? "";
}

/** Passes once the composer shows the Git branch, which the footer reads last. */
function gitShown(screen: string[]): void {
  expect(composerTop(screen)).toContain("footer-fixture");
}

/** Passes once no footer inspector or customiser remains on screen. */
function overlayClosed(screen: string[]): void {
  expect(screen.find((line) => /^Footer[:›]/.test(line))).toBeUndefined();
  gitShown(screen);
}

async function footer(
  terminal: PiTerminal,
  expected: string[],
  ready: (screen: string[]) => void = gitShown,
): Promise<void> {
  const compact = expected[1] === "";
  const actual = await terminal.settled((screen) => {
    const top = screen.findLastIndex((line) => line.startsWith("╭─ "));

    return {
      rows: composerStatusRows(screen, compact),
      below: screen.slice(top + (compact ? 2 : 3)).map((line) => line.trim()),
    };
  }, ready);

  expect(actual).toStrictEqual({
    rows: expected,
    below: actual.below.map(() => ""),
  });
}

async function restored(
  terminal: PiTerminal,
  expected: string[],
): Promise<void> {
  const rows = await terminal.settled(
    (screen) => composerStatusRows(screen, expected[1] === ""),
    overlayClosed,
  );

  expect(rows).toStrictEqual(expected);
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
    const clock = fixtureClock();
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
          ? ["-e", pretty, "-e", clockedFooter]
          : ["-e", clockedFooter, "-e", pretty]),
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
        ...clock.env,
      },
    });

    await terminal.until(async () => {
      expect(await readFile(updateLog, "utf8")).toBe("startup");
    }, [updateLog]);

    const rows = (step: keyof typeof footerRows) =>
      quiet ? footerRows[step].quiet : footerRows[step].rich;
    const wide = rows("wide");

    await footer(terminal, wide);
    await terminal.until((screen) => {
      expect(screen.join("\n")).toContain("Read (fixture.ts)");
    });

    expect(terminal.color()).toBeDefined();

    terminal.input("/fixture-publish first\r");
    terminal.input("/fixture-publish second\r");
    await terminal.until(async () => {
      expect(await readFile(updateLog, "utf8")).toBe("second");
    }, [updateLog]);

    await restored(terminal, wide);

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
    expect(
      await terminal.settled(statusRows, (screen) => {
        expect(editorRows(screen)).toContain("overflow 29");
      }),
    ).toStrictEqual(rows("overflow"));
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

    expect(
      await terminal.settled(statusRows, () => {
        expect(terminal.color("gpt-5.4")).not.toBe(originalColor);
      }),
    ).toStrictEqual(wide);

    terminal.input(`/fixture-theme ${theme}\r`);

    expect(
      await terminal.settled(statusRows, () => {
        expect(terminal.color("gpt-5.4")).toBe(originalColor);
      }),
    ).toStrictEqual(wide);

    terminal.resize(72);

    await footer(terminal, rows("narrow"), (screen) => {
      gitShown(screen);
      expect(visibleWidth(composerTop(screen))).toBe(72);
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

    terminal.input("/reload");
    await terminal.until((screen) => {
      const top = screen.findLastIndex((line) => line.startsWith("╭─ "));
      expect(screen[top + 1]).toContain("/reload");
    });
    terminal.input("\r");
    await terminal.until(async () => {
      expect(await latestSessionStart(startLog)).toBe("reload");
    }, [startLog]);
    await footer(terminal, wide);

    terminal.input("/new\r");
    await terminal.until(async () => {
      expect(await latestSessionStart(startLog)).toBe("new");
    }, [startLog]);
    expect(
      await terminal.settled(
        (screen) => composerStatusRows(screen, false),
        gitShown,
      ),
    ).toStrictEqual(rows("newSession"));
    terminal.input("/fixture-resume\r");
    await footer(terminal, wide);

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
    expect(
      await terminal.settled(
        (screen) => composerStatusRows(screen, false),
        (screen) => {
          expect(screen.join("\n")).toContain("Cannot load");
          expect(composerStatusRows(screen, false)[1]).toContain("◴");
          gitShown(screen);
        },
      ),
    ).toStrictEqual(rows("fallback"));
    expect(await readFile(join(agent, "session-footer.json"), "utf8")).toBe(
      '{"preset":"invalid"}',
    );
    clock.set(clockStart + 60_000);
    expect(
      await terminal.settled(
        (screen) => composerStatusRows(screen, false),
        (screen) => {
          gitShown(screen);
          expect(composerStatusRows(screen, false)[1]).not.toContain("stale");
        },
      ),
    ).toStrictEqual(rows("later"));
    expect({
      network: existsSync(networkLog),
      model: existsSync(modelLog),
    }).toStrictEqual({ network: false, model: false });
  },
);
