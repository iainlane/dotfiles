import {
  existsSync,
  lstatSync,
  readFileSync,
  symlinkSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { expect, it } from "vitest";
import { DemoWorkspace } from "#demo/workspace.ts";
import { demoFixture } from "#demo/fixture.ts";
import { PiTerminal } from "#test/support/terminal.ts";

function top(screen: string[]): string {
  return screen.findLast((line) => line.startsWith("╭─ ")) ?? "";
}

it.each(["local", "session", "managed"] as const)(
  "keeps one real-footer draft and saves only at the root for %s settings",
  async (mode) => {
    const workspace = DemoWorkspace.create(demoFixture);
    workspace.configure("http://127.0.0.1:1/v1", {
      preset: "rich",
      theme: "dark",
    });
    const base = join(workspace.agent, "session-footer.json");
    const user = join(workspace.agent, "session-footer.user.json");
    const target = join(workspace.agent, "base-settings.json");
    const original = JSON.stringify({
      preset: "rich",
      persistence: mode === "session" ? "session" : "local",
    });
    writeFileSync(base, original);
    if (mode === "managed") {
      writeFileSync(target, original);
      unlinkSync(base);
      symlinkSync(target, base);
    }
    const terminal = new PiTerminal({
      command: [
        ...workspace.command(process.env.PI_TEST_HOST ?? "pi"),
        "-e",
        fileURLToPath(
          new URL(import.meta.resolve("#test/fixtures/customiser.ts")),
        ),
      ],
      cwd: workspace.cwd,
      env: workspace.env,
      columns: 110,
      rows: 30,
    });
    terminal.resize(110, 30);
    try {
      await terminal.until((screen) => expect(top(screen)).toContain(""));
      terminal.input("/fixture-customise\r");
      await terminal.until((screen) =>
        expect(screen.join("\n")).toContain("Footer › Customise"),
      );
      terminal.input("\r");
      await terminal.until((screen) =>
        expect(screen.join("\n")).toContain("› Profile"),
      );
      terminal.input("\u001B[B\u001B[B");
      await terminal.until((screen) => {
        expect(top(screen)).not.toContain("");
        expect(top(screen)).toContain("");
        expect(readFileSync(base, "utf8")).toBe(original);
      });
      terminal.input("\r");
      await terminal.until((screen) =>
        expect(screen.join("\n")).toContain("not saved"),
      );
      expect({
        base: readFileSync(base, "utf8"),
        user: existsSync(user),
      }).toStrictEqual({ base: original, user: false });
      terminal.input("\u001B[B".repeat(5));
      await terminal.until((screen) =>
        expect(screen.join("\n")).toContain(
          mode === "session" ? "enter use" : "enter save",
        ),
      );
      terminal.input("\r");
      await terminal.until((screen) =>
        expect({
          confirmation: screen.join("\n").includes("Save user settings"),
          closed: !screen.join("\n").includes("Footer › Customise"),
        }).toStrictEqual(
          mode === "managed"
            ? { confirmation: true, closed: false }
            : { confirmation: false, closed: true },
        ),
      );
      expect({
        link: lstatSync(base).isSymbolicLink(),
        target: existsSync(target) ? readFileSync(target, "utf8") : undefined,
        user: existsSync(user),
      }).toStrictEqual({
        link: mode === "managed",
        target: mode === "managed" ? original : undefined,
        user: false,
      });
      if (mode === "managed") {
        terminal.input("\r");
      }
      await terminal.until((screen) => {
        expect(screen.join("\n")).not.toContain("Footer › Customise");
        expect(screen.join("\n")).toContain("unchanged draft 界é");
        expect(top(screen)).not.toContain("");
      });
      const document: unknown = JSON.parse(
        readFileSync(mode === "managed" ? user : base, "utf8"),
      );
      const expected = {
        session: { preset: "rich", persistence: "session" },
        managed: { preset: "minimal" },
        local: { preset: "minimal", persistence: "local" },
      };
      expect({
        document,
        model: existsSync(join(workspace.cwd, "unexpected-model-turn")),
      }).toStrictEqual({ document: expected[mode], model: false });
    } catch (error) {
      throw new Error(
        `${(await terminal.screen()).join("\n")}\n${terminal.diagnostics()}`,
        { cause: error },
      );
    } finally {
      await terminal.close();
      workspace.close();
    }
  },
);

it("hands off from the inspector overlay to one live customiser and returns focus to the draft", async () => {
  const workspace = DemoWorkspace.create(demoFixture);
  workspace.configure("http://127.0.0.1:1/v1", {
    preset: "rich",
    theme: "dark",
  });
  const base = join(workspace.agent, "session-footer.json");
  const original = readFileSync(base, "utf8");
  const terminal = new PiTerminal({
    command: [
      ...workspace.command(process.env.PI_TEST_HOST ?? "pi"),
      "-e",
      fileURLToPath(
        new URL(import.meta.resolve("#test/fixtures/customiser.ts")),
      ),
    ],
    cwd: workspace.cwd,
    env: workspace.env,
    columns: 110,
    rows: 30,
  });
  terminal.resize(110, 30);
  try {
    await terminal.until((screen) => expect(top(screen)).toContain(""));
    terminal.input("/fixture-customise explain\r");
    await terminal.until((screen) =>
      expect(screen.join("\n")).toContain("Footer › Explain"),
    );
    terminal.input("s");
    await terminal.until((screen) =>
      expect(screen.join("\n")).toContain("Footer › Sections"),
    );
    terminal.input("\u001B[B".repeat(8));
    await terminal.until((screen) =>
      expect(screen.join("\n")).toContain("› Customise…"),
    );
    terminal.input("\r");
    await terminal.until((screen) => {
      expect(screen.join("\n")).toContain("Footer › Customise");
      expect(screen.join("\n")).not.toContain("Footer › Sections");
      expect(screen.join("\n")).toContain("unchanged draft 界é");
    });
    terminal.input("\r");
    await terminal.until((screen) =>
      expect(screen.join("\n")).toContain("› Profile"),
    );
    terminal.input("\u001B[B\u001B[B");
    await terminal.until((screen) => {
      expect(top(screen)).not.toContain("");
      expect(top(screen)).toContain("");
    });
    terminal.input("\u001B");
    await terminal.until((screen) => {
      expect(screen.join("\n")).not.toContain("› Profile");
      expect(top(screen)).toContain("");
    });
    terminal.input("\u001B");
    await terminal.until((screen) =>
      expect(screen.join("\n")).not.toContain("Footer › Customise"),
    );
    terminal.input("!");
    await terminal.until((screen) =>
      expect(screen.join("\n")).toContain("second line!"),
    );
    expect({
      base: readFileSync(base, "utf8"),
      model: existsSync(join(workspace.cwd, "unexpected-model-turn")),
    }).toStrictEqual({ base: original, model: false });
  } catch (error) {
    throw new Error(
      `${(await terminal.screen()).join("\n")}\n${terminal.diagnostics()}`,
      { cause: error },
    );
  } finally {
    await terminal.close();
    workspace.close();
  }
});
