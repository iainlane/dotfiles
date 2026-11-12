import { execFile } from "node:child_process";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { expect, it } from "vitest";
import { PiTerminal } from "#test/support/terminal.ts";
import { demoFixture } from "#demo/fixture.ts";

it.each(["rich", "minimal"])(
  "runs the isolated %s demo against its scripted local provider",
  async (preset) => {
    const root = fileURLToPath(new URL("../../", import.meta.url));
    const terminal = new PiTerminal({
      command: [process.execPath, "demo/run.ts", "--preset", preset],
      cwd: root,
      env: { ...process.env, PI_TEST_HOST: process.env.PI_TEST_HOST ?? "pi" },
      columns: 100,
      rows: 24,
    });
    await terminal.until((screen) => {
      expect(screen.join("\n")).toContain(demoFixture.git.branch);
      expect(screen.join("\n")).toContain("╭─");
    });
    terminal.input(`${demoFixture.prompt}\r`);
    await terminal.until((screen) => {
      const value = screen.join("\n");
      expect({
        response: value.includes(
          demoFixture.response.map((chunk) => chunk.text).join(""),
        ),
        context: value.includes("◫"),
        cache: value.includes(
          ` ${((demoFixture.usage.cachedTokens / demoFixture.usage.promptTokens) * 100).toFixed(1)}%`,
        ),
      }).toStrictEqual({
        response: true,
        context: true,
        cache: preset === "rich",
      });
    });
    terminal.input("/footer help\r");
    await terminal.until((screen) => {
      expect(screen.join("\n")).toContain("/footer explain");
      expect(screen.join("\n")).not.toContain("Extension errors");
    });
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
