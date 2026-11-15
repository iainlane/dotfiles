import { execFile } from "node:child_process";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { expect, it, onTestFinished } from "vitest";
import { DemoProvider } from "#demo/provider.ts";
import { demoFixture } from "#demo/fixture.ts";
import { DemoWorkspace } from "#demo/workspace.ts";
import { clockedFooter, fixtureClock } from "#test/support/fixture-clock.ts";
import { PiTerminal } from "#test/support/terminal.ts";

/** The composer's top and bottom border rows, which show the footer. */
function footerRows(screen: string[]): string[] {
  return [
    screen.findLast((line) => line.startsWith("╭─ ")) ?? "",
    screen.findLast((line) => line.startsWith("╰─")) ?? "",
  ];
}

it("runs the isolated demo against its scripted local provider", async () => {
  const root = fileURLToPath(new URL("../../", import.meta.url));
  const terminal = new PiTerminal({
    command: [process.execPath, "demo/run.ts"],
    cwd: root,
    env: { ...process.env, PI_TEST_HOST: process.env.PI_TEST_HOST ?? "pi" },
    columns: 100,
    rows: 24,
  });
  const answer = demoFixture.response.map((chunk) => chunk.text).join("");

  await terminal.until((screen) => {
    expect(screen.some((line) => line.startsWith("╭─ "))).toBe(true);
  });
  terminal.input(`${demoFixture.prompt}\r`);
  await terminal.until((screen) => {
    expect(screen.join("\n")).toContain(answer);
  });
});

const expectedRows = {
  rich: {
    before: [
      "╭─  footer-demo/scripted-demo  ◒ high   ~/workspace   footer-demo ✚1 ✎1 ?1   ◫ 0.0%/131.1k ─╮",
      "╰─                                                                                                ─╯",
    ],
    after: [
      "╭─  footer-demo/scripted-demo  ◒ high   workspace   footer-demo ✚1 ✎1 ?1    ◫ 12.7%/131.1k ─╮",
      "╰─                                                                        25.0%  ≈$0.03   0m ─╯",
    ],
  },
  minimal: {
    before: [
      "╭─  ~/workspace   footer-demo ✚1 ✎1 ?1 ───────────────────────────────────────  ◫ 0.0%/131.1k ─╮",
      "╰─                                                                                                ─╯",
    ],
    after: [
      "╭─  ~/workspace   footer-demo ✚1 ✎1 ?1 ━━━━━─────────────────────────────────  ◫ 12.7%/131.1k ─╮",
      "╰─                                                                                                ─╯",
    ],
  },
};

it.each(["rich", "minimal"] as const)(
  "shows the %s footer before and after the scripted response",
  async (preset) => {
    const workspace = DemoWorkspace.create(demoFixture);
    onTestFinished(() => workspace.close());
    const provider = await DemoProvider.start(demoFixture);
    onTestFinished(() => provider.close());
    workspace.configure(provider.url, { preset, theme: "dark" });
    const terminal = new PiTerminal({
      command: workspace.command(
        process.env.PI_TEST_HOST ?? "pi",
        clockedFooter,
      ),
      cwd: workspace.cwd,
      env: { ...workspace.env, ...fixtureClock().env },
      columns: 100,
      rows: 24,
    });
    const answer = demoFixture.response.map((chunk) => chunk.text).join("");

    expect(
      await terminal.settled(footerRows, (screen) => {
        expect(footerRows(screen)[0]).toContain("footer-demo ✚");
      }),
    ).toStrictEqual(expectedRows[preset].before);
    terminal.input(`${demoFixture.prompt}\r`);
    expect(
      await terminal.settled(footerRows, (screen) => {
        expect(screen.join("\n")).toContain(answer);
      }),
    ).toStrictEqual(expectedRows[preset].after);
  },
);

it("exits after closing a provider with a delayed response", async ({
  signal,
}) => {
  const provider = new URL(import.meta.resolve("#demo/provider.ts")).href;
  const fixture = new URL(import.meta.resolve("#demo/fixture.ts")).href;
  const { stdout } = await promisify(execFile)(
    process.execPath,
    [
      "--input-type=module",
      "-e",
      `
    const { DemoProvider } = await import(${JSON.stringify(provider)});
    const { demoFixture } = await import(${JSON.stringify(fixture)});
    const server = await DemoProvider.start({
      ...demoFixture, response: [{ atMs: 3_600_000, text: "delayed" }],
    });
    const response = await fetch(server.url + "/chat/completions", {
      method: "POST", body: JSON.stringify({ model: demoFixture.model.id }),
    });
    const body = response.text().catch(() => "closed");
    await server.close();
    await body;
    console.log("closed");
  `,
    ],
    { encoding: "utf8", signal },
  );
  expect(stdout).toBe("closed\n");
});
