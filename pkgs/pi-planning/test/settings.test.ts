import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, it, vi } from "vitest";
import { readPlanningSettings } from "#planning/settings.ts";

const directories: string[] = [];
afterEach(() => {
  vi.unstubAllEnvs();
  for (const directory of directories.splice(0)) {
    rmSync(directory, { recursive: true, force: true });
  }
});

function writeSettings(value: unknown): string {
  const directory = mkdtempSync(join(tmpdir(), "pi-planning-settings-"));
  directories.push(directory);
  vi.stubEnv("PI_CODING_AGENT_DIR", directory);
  const path = join(directory, "planning.json");
  writeFileSync(path, JSON.stringify(value));
  return path;
}

it.each([{}, { researchExtensions: ["extension.ts"], future: true }])(
  "accepts native research extension settings: %j",
  (settings) => {
    writeSettings(settings);
    expect(readPlanningSettings()).toStrictEqual(settings);
  },
);

it.each([
  null,
  [],
  { researchExtensions: "extension.ts" },
  { researchExtensions: [1] },
])("rejects malformed planning settings: %j", (value) => {
  const path = writeSettings(value);
  expect(() => readPlanningSettings()).toThrow(
    new Error(`Cannot read planning settings at ${path}.`, {
      cause: new Error(
        "planning.json must be an object with an optional researchExtensions array of extension paths.",
      ),
    }),
  );
});
