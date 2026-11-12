import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { expect, it, onTestFinished } from "vitest";
import { visibleWidth } from "@earendil-works/pi-tui";
import { DemoWorkspace } from "#demo/workspace.ts";
import { demoFixture } from "#demo/fixture.ts";
import { record } from "#footer/shared/text.ts";
import { PiTerminal } from "#test/support/terminal.ts";

it.each(["regular", "fullscreen"])(
  "pauses safely after a late widget in %s mode",
  async (mode) => {
    const workspace = DemoWorkspace.create(demoFixture);
    onTestFinished(() => workspace.close());
    workspace.configure("http://127.0.0.1:1/v1", {
      preset: "rich",
      theme: "dark",
    });
    const terminal = new PiTerminal({
      command: [
        process.env.PI_TEST_HOST ?? "pi",
        "--offline",
        "--no-extensions",
        "--no-mcp",
        "--no-skills",
        "--no-context-files",
        "--no-prompt-templates",
        "--no-tools",
        "--tui-mode",
        mode,
        "--provider",
        demoFixture.model.provider,
        "--model",
        demoFixture.model.id,
        "-e",
        fileURLToPath(new URL(import.meta.resolve("#test/fixtures/dock.ts"))),
      ],
      cwd: workspace.cwd,
      env: workspace.env,
      columns: 100,
      rows: 24,
    });
    await terminal.until((screen) =>
      expect(screen.join("\n")).toContain("dock-model"),
    );
    terminal.input("/dock-preview\r");
    await terminal.until((screen) =>
      expect(screen.join("\n")).toContain("Footer dock gate · Profile"),
    );
    terminal.input("c");
    await terminal.until((screen) => expect(border(screen)).not.toContain("≡"));
    terminal.resize(70, 14);
    terminal.input("w");
    const stateLog = join(workspace.cwd, "dock-preview-state.json");
    await terminal.until(
      async (screen) => {
        expect(screen.join("\n")).toContain("More room needed");
        expect(JSON.parse(await readFile(stateLog, "utf8"))).toStrictEqual({
          visible: false,
          preset: "rich",
          changes: 1,
        });
      },
      [stateLog],
    );
    terminal.input("\r");
    await terminal.until(
      async (screen) => {
        expect(screen.join("\n")).toContain("More room needed");
        expect(JSON.parse(await readFile(stateLog, "utf8"))).toStrictEqual({
          visible: false,
          preset: "rich",
          changes: 3,
        });
      },
      [stateLog],
    );
    terminal.resize(100, 30);
    await terminal.until((screen) =>
      expect(visibleWidth(border(screen))).toBe(100),
    );
    terminal.input("\r");
    await terminal.until(
      async (screen) => {
        expect(screen.join("\n")).not.toContain("More room needed");
        expect(screen.join("\n")).toContain("Footer dock gate · Profile");
        expect(JSON.parse(await readFile(stateLog, "utf8"))).toStrictEqual({
          visible: true,
          preset: "compact",
          changes: 4,
        });
      },
      [stateLog],
    );
    terminal.input("\u001B");
    const resultLog = join(workspace.cwd, "dock-result.json");
    await terminal.until(async () => {
      const result: unknown = JSON.parse(await readFile(resultLog, "utf8"));
      if (!record(result)) {
        throw new Error("Expected a completed dock");
      }
      expect(result).toStrictEqual({
        factory: true,
        instance: true,
        mounts: 0,
        modelTurns: 0,
        draft: "draft 界é\nsecond line\nthird line",
        cursor: result.expectedCursor,
        expectedCursor: result.expectedCursor,
        focus: true,
      });
    }, [resultLog]);
  },
);

function border(screen: string[]): string {
  return screen.findLast((line) => line.startsWith("╰─ ")) ?? "";
}

it.each([
  { mode: "fullscreen", prettyFirst: true, long: false },
  { mode: "regular", prettyFirst: false, long: false },
  { mode: "fullscreen", prettyFirst: false, long: true },
  { mode: "regular", prettyFirst: true, long: true },
])(
  "previews in a native $mode dock with Pretty first=$prettyFirst and long=$long",
  async ({ mode, prettyFirst, long }) => {
    const pretty = process.env.PI_TEST_PRETTY;
    if (pretty === undefined || pretty === "") {
      throw new Error(
        "Set PI_TEST_PRETTY to the installed Pretty package root",
      );
    }
    const workspace = DemoWorkspace.create(demoFixture);
    onTestFinished(() => workspace.close());
    workspace.configure("http://127.0.0.1:1/v1", {
      preset: "rich",
      theme: "dark",
    });
    const fixture = fileURLToPath(
      new URL(import.meta.resolve("#test/fixtures/dock.ts")),
    );
    const terminal = new PiTerminal({
      command: [
        process.env.PI_TEST_HOST ?? "pi",
        "--offline",
        "--no-extensions",
        "--no-mcp",
        "--no-skills",
        "--no-context-files",
        "--no-prompt-templates",
        "--no-tools",
        "--tui-mode",
        mode,
        "--provider",
        demoFixture.model.provider,
        "--model",
        demoFixture.model.id,
        ...(prettyFirst ? [pretty, fixture] : [fixture, pretty]).flatMap(
          (path) => ["-e", path],
        ),
      ],
      cwd: workspace.cwd,
      env: workspace.env,
      columns: 100,
      rows: 24,
    });
    const log = join(workspace.cwd, "dock-result.json");
    await terminal.until((screen) =>
      expect(screen.join("\n")).toContain("dock-model"),
    );
    terminal.input(`/dock-preview${long ? " long" : ""}\r`);
    if (long) {
      terminal.input("\r");
    }
    await terminal.until((screen) => {
      const title = screen.findIndex((line) =>
        line.includes("Footer dock gate · Profile"),
      );
      const top = screen.findLastIndex((line) => line.startsWith("╭─ "));
      expect({
        title: title >= 0,
        below: top > title,
        editors: screen.filter((line) => line.startsWith("╭─ ")).length,
        symbol: border(screen).includes("≡"),
      }).toStrictEqual({
        title: true,
        below: true,
        editors: 1,
        symbol: true,
      });
    });
    terminal.input("c");
    await terminal.until((screen) => {
      expect(border(screen)).not.toContain("≡");
      expect(screen.join("\n")).toContain("Footer dock gate · Profile");
    });
    terminal.input("r");
    await terminal.until((screen) => expect(border(screen)).toContain("≡"));
    terminal.input("i");
    await terminal.until((screen) =>
      expect(screen.join("\n")).toContain("Footer dock gate · Symbol"),
    );
    terminal.input("\u0015[P]");
    await terminal.until((screen) => expect(border(screen)).toContain("[P]"));
    terminal.input("\r");
    await terminal.until((screen) =>
      expect(screen.join("\n")).toContain("Footer dock gate · Profile"),
    );
    terminal.resize(70, 14);
    await terminal.until((screen) => {
      expect({
        controls: screen.join("\n").includes("Footer dock gate · Profile"),
        preview: border(screen).includes("[P]"),
      }).toStrictEqual({ controls: true, preview: true });
    });
    terminal.resize(100, 24);
    terminal.input("o");
    await terminal.until((screen) =>
      expect(screen.join("\n")).toContain("Nested focus check"),
    );
    terminal.input("\u001B");
    await terminal.until((screen) =>
      expect(screen.join("\n")).not.toContain("Nested focus check"),
    );
    terminal.input("o");
    await terminal.until((screen) =>
      expect(screen.join("\n")).toContain("Nested focus check"),
    );
    terminal.input("x");
    await terminal.until(
      async (screen) => {
        const result: unknown = JSON.parse(await readFile(log, "utf8"));
        if (!record(result)) {
          throw new Error("Expected native focus verification");
        }
        expect(result).toStrictEqual({
          factory: true,
          instance: true,
          mounts: 0,
          modelTurns: 0,
          draft: long
            ? Array.from(
                { length: 30 },
                (_, index) => `draft line ${index}`,
              ).join("\n")
            : "draft 界é\nsecond line\nthird line",
          cursor: result.expectedCursor,
          expectedCursor: result.expectedCursor,
          focus: true,
        });
        expect(screen.join("\n")).not.toContain("Footer dock gate");
        expect(border(screen)).toContain("≡");
      },
      [log],
    );
  },
);
