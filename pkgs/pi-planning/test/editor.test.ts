import { mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it, vi } from "vitest";
import {
  editorName,
  openPlanEditor,
  openPlanEditorInTerminal,
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

it.each([false, true])(
  "restores native terminal state after editing (failure: %s)",
  async (failure) => {
    const directory = await mkdtemp(join(tmpdir(), "pi-plan-terminal-"));
    try {
      const path = join(directory, "plan.md");
      await writeFile(path, "before");
      const calls: string[] = [];
      const tui = {
        stop: vi.fn<() => void>(() => {
          calls.push("stop");
        }),
        start: vi.fn<() => void>(() => {
          calls.push("start");
        }),
        requestRender: vi.fn<(force?: boolean) => void>(() => {
          calls.push("render");
        }),
      };
      const script = `require("node:fs").writeFileSync(process.argv[1], "after"); process.exit(${failure ? 7 : 0});`;
      const opening = openPlanEditorInTerminal(
        tui,
        path,
        `"${process.execPath}" -e '${script}'`,
      );
      let error: Error | undefined;
      try {
        await opening;
      } catch (cause) {
        if (!(cause instanceof Error)) {
          throw cause;
        }
        error = cause;
      }
      expect({
        calls,
        content: await readFile(path, "utf8"),
        render: tui.requestRender.mock.calls,
        error: error?.message,
      }).toStrictEqual({
        calls: ["stop", "start", "render"],
        content: "after",
        render: [[true]],
        error: failure
          ? "The editor exited with status 7. Use a wait-capable editor command."
          : undefined,
      });
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  },
);

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

it.each([
  "",
  "nvim; touch project.ts",
  "nvim | tee project.ts",
  "nvim > project.ts",
  "nvim $(touch project.ts)",
  "OPTION=value nvim",
])("rejects unsupported editor shell syntax: %s", async (command) => {
  await expect(openPlanEditor("/unused-plan", command)).rejects.toThrow(
    /executable|literal|shell/,
  );
});

it("reports an editor startup failure", async () => {
  await expect(
    openPlanEditor("/unused-plan", "/missing/planning-editor"),
  ).rejects.toThrow("Cannot start editor");
});

it("reports a nonzero editor exit", async () => {
  await expect(
    openPlanEditor(
      "/unused-plan",
      `"${process.execPath}" -e 'process.exit(7)'`,
    ),
  ).rejects.toThrow("status 7");
});
