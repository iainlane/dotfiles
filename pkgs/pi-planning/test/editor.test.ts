import { writeFileSync } from "node:fs";
import { mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it, onTestFinished } from "vitest";
import {
  EditorCommandError,
  EditorExitError,
  EditorStartError,
  editorName,
  openPlanEditor,
  openPlanEditorInUi,
} from "#planning/editor.ts";

it.each([
  { command: "nvim", name: "nvim" },
  { command: "/usr/bin/vi -f", name: "vi" },
  { command: '"/Applications/Editor App/editor" --wait', name: "editor" },
  { command: "", name: "the configured editor" },
  { command: "nvim | tee other.md", name: "the configured editor" },
])("describes the configured editor $command", ({ command, name }) => {
  expect(editorName(command)).toBe(name);
});

/**
 * A terminal that Pi shares with the editor. The editor runs in another
 * process, so the terminal's owner and the screen contents are files. Like
 * Pi's TUI, an ordinary render rewrites the screen only when Pi's frame has
 * changed, and a forced render rewrites the whole screen. After the editor
 * draws over the screen, only a forced render restores Pi's frame.
 */
class SharedTerminal {
  static readonly frame = "Pi's session";
  private drawn: string | undefined;
  private readonly owner: string;
  private readonly screen: string;

  constructor(owner: string, screen: string) {
    this.owner = owner;
    this.screen = screen;
    this.start();
    this.requestRender();
  }

  stop(): void {
    writeFileSync(this.owner, "editor");
  }

  start(): void {
    writeFileSync(this.owner, "pi");
  }

  requestRender(force = false): void {
    if (!force && this.drawn === SharedTerminal.frame) {
      return;
    }
    writeFileSync(this.screen, SharedTerminal.frame);
    this.drawn = SharedTerminal.frame;
  }
}

async function editInSharedTerminal(status: number) {
  const directory = await mkdtemp(join(tmpdir(), "pi-plan-terminal-"));
  onTestFinished(() => rm(directory, { recursive: true, force: true }));
  const path = join(directory, "plan.md");
  await writeFile(path, "before");
  const owner = join(directory, "terminal-owner");
  const screen = join(directory, "terminal-screen");
  const terminal = new SharedTerminal(owner, screen);
  const notifications: string[] = [];
  const script = `const fs = require("node:fs"); fs.writeFileSync(process.argv[1], "edited while the terminal belonged to " + fs.readFileSync(${JSON.stringify(owner)}, "utf8")); fs.writeFileSync(${JSON.stringify(screen)}, "the editor screen"); process.exit(${String(status)});`;
  const opening = openPlanEditorInUi(
    {
      hasUI: true,
      mode: "tui",
      ui: {
        notify: (message) => notifications.push(message),
        custom: (factory) =>
          new Promise((resolve) => {
            factory(terminal, undefined, undefined, resolve);
          }),
      },
    },
    path,
    `"${process.execPath}" -e '${script}'`,
  );
  return {
    opening,
    state: async () => ({
      content: await readFile(path, "utf8"),
      owner: await readFile(owner, "utf8"),
      screen: await readFile(screen, "utf8"),
      notifications,
    }),
  };
}

const restored = {
  content: "edited while the terminal belonged to editor",
  owner: "pi",
  screen: SharedTerminal.frame,
  notifications: [],
};

it("hands the terminal to the editor and restores it afterwards", async () => {
  const edit = await editInSharedTerminal(0);
  await expect(edit.opening).resolves.toBeUndefined();
  expect(await edit.state()).toStrictEqual(restored);
});

it("restores the terminal when the editor fails", async () => {
  const edit = await editInSharedTerminal(7);
  await expect(edit.opening).rejects.toStrictEqual(
    new EditorExitError(7, null),
  );
  expect(await edit.state()).toStrictEqual(restored);
});

it("passes the actual plan path to a quoted editor command without using a shell", async () => {
  const directory = await mkdtemp(join(tmpdir(), "pi-plan-editor-"));
  try {
    const executable = join(directory, "editor with spaces");
    const plan = join(directory, "plan with 'quotes' and spaces.md");
    await symlink(process.execPath, executable);
    await writeFile(plan, "original");
    const script =
      'import { writeFileSync } from "node:fs"; writeFileSync(process.argv[1], "edited");';
    await openPlanEditor(
      plan,
      `"${executable}" --input-type=module -e '${script}'`,
    );
    expect(await readFile(plan, "utf8")).toBe("edited");
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

const singleCommand =
  "Configure the editor as one executable with literal arguments.";
const expansion =
  "Editor commands cannot include shell expansion or redirection. Use an editor wrapper script if needed.";

it.each([
  { command: "", message: singleCommand },
  { command: "nvim; touch project.ts", message: singleCommand },
  { command: "nvim | tee project.ts", message: singleCommand },
  { command: "nvim > project.ts", message: expansion },
  { command: "nvim $(touch project.ts)", message: expansion },
  { command: "OPTION=value nvim", message: singleCommand },
])(
  "rejects unsupported editor shell syntax: $command",
  async ({ command, message }) => {
    await expect(openPlanEditor("/unused-plan", command)).rejects.toStrictEqual(
      new EditorCommandError(message),
    );
  },
);

it("reports an editor startup failure", async () => {
  await expect(
    openPlanEditor("/unused-plan", "/missing/planning-editor"),
  ).rejects.toStrictEqual(
    new EditorStartError(
      "/missing/planning-editor",
      expect.objectContaining({ code: "ENOENT" }),
    ),
  );
});

it("reports a nonzero editor exit", async () => {
  await expect(
    openPlanEditor(
      "/unused-plan",
      `"${process.execPath}" -e 'process.exit(7)'`,
    ),
  ).rejects.toStrictEqual(new EditorExitError(7, null));
});
