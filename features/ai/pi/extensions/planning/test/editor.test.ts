import { mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it } from "vitest";
import { openPlanEditor } from "../src/editor.ts";

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
