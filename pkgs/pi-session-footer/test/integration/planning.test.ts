import { randomUUID } from "node:crypto";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { expect, it, onTestFinished } from "vitest";
import { latestSessionStart } from "#test/support/session-starts.ts";
import { PiTerminal } from "#test/support/terminal.ts";

it.each([true, false])(
  "cooperates with real planning, planning first=%s",
  async (planningFirst) => {
    const host = process.env.PI_TEST_HOST;
    const planning = process.env.PI_TEST_PLANNING;
    if (
      host === undefined ||
      host === "" ||
      planning === undefined ||
      planning === ""
    ) {
      throw new Error(
        "Set PI_TEST_HOST and PI_TEST_PLANNING to installed package paths",
      );
    }
    const root = await mkdtemp(join(tmpdir(), "pi-footer-planning-"));
    onTestFinished(() => rm(root, { recursive: true, force: true }));
    const agent = join(root, "agent");
    const session = join(root, "session.jsonl");
    const starts = join(root, "starts.log");
    await mkdir(agent);
    await writeFile(
      session,
      JSON.stringify({
        type: "session",
        version: 3,
        id: randomUUID(),
        timestamp: new Date().toISOString(),
        cwd: root,
      }) + "\n",
    );
    await writeFile(
      join(agent, "settings.json"),
      JSON.stringify({ quietStartup: "all" }),
    );
    await writeFile(
      join(agent, "session-footer.json"),
      JSON.stringify({
        "top-left": ["directory"],
        "top-right": [],
        "bottom-left": ["planning", "statuses"],
        "bottom-right": [],
        symbols: { planning: "[P]" },
      }),
    );
    const footer = fileURLToPath(new URL(import.meta.resolve("#footer-entry")));
    const terminal = new PiTerminal({
      command: [
        host,
        "--offline",
        "--no-extensions",
        "--no-skills",
        "--no-mcp",
        "--no-context-files",
        "--no-prompt-templates",
        "--no-approve",
        "--session",
        session,
        "-e",
        join(planning, "node_modules/pi-subagents"),
        ...[
          ...(planningFirst ? [planning, footer] : [footer, planning]),
          fileURLToPath(
            new URL(import.meta.resolve("#test/fixtures/planning.ts")),
          ),
        ].flatMap((path) => ["-e", path]),
        "--plan",
      ],
      cwd: root,
      columns: 120,
      rows: 24,
      env: {
        PATH: process.env.PATH ?? "",
        HOME: root,
        TMPDIR: root,
        TERM: "xterm-256color",
        PI_CODING_AGENT_DIR: agent,
        PI_OFFLINE: "1",
        PI_SKIP_VERSION_CHECK: "1",
        PI_FOOTER_START_LOG: starts,
        PI_FOOTER_SESSION: session,
      },
    });
    const planningBorder = `╰─ [P]${"─".repeat(111)} ─╯`;
    const emptyBorder = `╰─${" ".repeat(116)}─╯`;
    const active = async (border: string) => {
      expect(
        await terminal.settled(
          (screen) => screen.findLast((line) => line.startsWith("╰─ ")),
          (screen) => {
            expect(
              screen.findLast((line) => line.startsWith("╭─ ")),
            ).toBeDefined();
          },
        ),
      ).toBe(border);
    };
    const replace = async (command: string, reason: string, border: string) => {
      terminal.input(command + "\r");
      await terminal.until(async () => {
        expect(await latestSessionStart(starts)).toBe(reason);
      }, [starts]);
      await active(border);
    };
    await active(planningBorder);
    await replace("/reload", "reload", planningBorder);
    await replace("/new", "new", emptyBorder);
    await replace("/fixture-resume", "resume", planningBorder);
    terminal.input("/plan exit\r");
    await active(emptyBorder);
    await replace("/reload", "reload", emptyBorder);
    terminal.input("/plan\r");
    await active(planningBorder);
  },
);
