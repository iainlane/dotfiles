import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { expect, it } from "vitest";
import { DemoWorkspace } from "#demo/workspace.ts";
import { demoFixture } from "#demo/fixture.ts";
import { PiTerminal } from "#test/support/terminal.ts";

class CustomiserDriver {
  constructor(readonly terminal: PiTerminal) {}
  private heading(screen: string[]): string {
    return screen.find((line) => line.startsWith("Footer › Customise")) ?? "";
  }
  private selected(screen: string[]): string {
    return screen.find((line) => line.startsWith("→ ")) ?? "";
  }
  async select(label: string): Promise<void> {
    let previous = "";
    await this.terminal.until((screen) => {
      const selected = this.selected(screen);
      if (selected.includes(label)) {
        return;
      }
      if (selected !== "" && selected !== previous) {
        previous = selected;
        this.terminal.input("\u001B[B");
      }
      throw new Error(`Waiting to select ${label}`);
    });
  }
  async open(label: string): Promise<void> {
    await this.select(label);
    await this.accept();
  }
  async accept(): Promise<void> {
    const previous = this.page(await this.terminal.screen());
    this.terminal.input("\r");
    await this.changedPage(previous);
  }
  private page(screen: string[]): string {
    return `${this.heading(screen)}\n${this.selected(screen)}`;
  }
  private changedPage(previous: string): Promise<void> {
    return this.terminal.until((screen) => {
      if (this.page(screen) === previous) {
        throw new Error(`Waiting to leave ${previous}`);
      }
    });
  }
  async back(): Promise<void> {
    const previous = this.page(await this.terminal.screen());
    this.terminal.input("\u001B");
    await this.changedPage(previous);
  }
  async root(): Promise<void> {
    let previous = "";
    await this.terminal.until((screen) => {
      const heading = this.heading(screen);
      if (heading === "Footer › Customise") {
        return;
      }
      const page = this.page(screen);
      if (heading !== "" && page !== previous) {
        previous = page;
        this.terminal.input("\u001B");
      }
      throw new Error("Returning to the customiser root");
    });
  }
  async symbol(value: string): Promise<void> {
    await this.open("Symbol");
    this.terminal.input("Custom text");
    await this.terminal.until((screen) => {
      if (
        !screen.some(
          (line) => line.startsWith("Search: ") && line.includes("Custom text"),
        )
      ) {
        throw new Error("Waiting for the symbol search");
      }
    });
    await this.open("Custom text");
    this.terminal.input(value);
  }
}

it.each([
  { action: "cancel", replacement: false },
  { action: "save", replacement: false },
  { action: "cancel", replacement: true },
] as const)(
  "keeps one real-footer draft until $action with replacement=$replacement",
  async ({ action, replacement }) => {
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
    const ui = new CustomiserDriver(terminal);
    try {
      await terminal.until((screen) =>
        expect(screen.join("\n")).toContain(""),
      );
      terminal.input(`/fixture-customise${replacement ? " replace" : ""}\r`);
      await terminal.until((screen) =>
        expect(screen.join("\n")).toContain("Footer › Customise"),
      );
      await terminal.until((screen) =>
        expect(screen.join("\n").includes("standalone footer")).toBe(
          replacement,
        ),
      );
      await ui.open("Widgets");
      await ui.open("Top left");
      await ui.open("Git");
      await ui.open("Customise");
      await ui.symbol("[G]");
      await terminal.until((screen) =>
        expect(screen.join("\n")).toContain("[G] footer-demo"),
      );
      await ui.back();
      await ui.back();
      await terminal.until((screen) =>
        expect(screen.join("\n")).not.toContain("[G] footer-demo"),
      );
      await ui.symbol("git");
      await terminal.until((screen) =>
        expect(screen.join("\n")).toContain("git footer-demo"),
      );
      await ui.accept();
      await ui.open("Symbol colour");
      await ui.open("Accent");
      await ui.open("Text colour");
      await ui.open("Text");
      await terminal.until(() => {
        const marker = terminal.style("git footer-demo");
        const branch = terminal.style("footer-demo ✚");
        expect({
          marker: marker !== undefined,
          branch: branch !== undefined,
          independent: marker?.color !== branch?.color,
        }).toStrictEqual({ marker: true, branch: true, independent: true });
      });
      await ui.root();
      await ui.open("Separators");
      await ui.open("Between widgets");
      await ui.open("Custom");
      terminal.input(" · ");
      await terminal.until((screen) =>
        expect(screen.join("\n")).toContain("Spaces: ␠·␠"),
      );
      await ui.accept();
      await ui.back();
      await ui.open("Extension symbols");
      await ui.open("planning");
      await ui.symbol("[P]");
      await ui.accept();
      await ui.root();
      expect({
        base: readFileSync(base, "utf8"),
        user: existsSync(join(workspace.agent, "session-footer.user.json")),
      }).toStrictEqual({ base: original, user: false });
      if (action === "cancel") {
        await ui.back();
      }
      if (action === "save") {
        await ui.open("Save & use");
      }
      await terminal.until((screen) => {
        const display = screen.join("\n");
        expect({
          closed: !display.includes("Footer › Customise"),
          draft: display.includes("unchanged draft 界é"),
          literal: display.includes("git footer-demo"),
          separator: display.includes(" · "),
        }).toStrictEqual({
          closed: true,
          draft: true,
          literal: action === "save",
          separator: action === "save",
        });
      });
      terminal.input("!");
      await terminal.until((screen) =>
        expect(screen.join("\n")).toContain("second line!"),
      );
      const document: unknown = JSON.parse(readFileSync(base, "utf8"));
      expect({
        document,
        model: existsSync(join(workspace.cwd, "unexpected-model-turn")),
      }).toStrictEqual({
        document:
          action === "cancel"
            ? { preset: "rich" }
            : {
                preset: "rich",
                "top-left": [
                  "model",
                  "thinking",
                  "tier",
                  "directory",
                  {
                    id: "git",
                    symbol: { text: "git", colour: "accent" },
                    colour: "text",
                  },
                  "git-operation",
                  "git-conflicts",
                  "pr",
                ],
                separators: { widgets: " · " },
                symbols: { planning: "[P]" },
              },
        model: false,
      });
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
