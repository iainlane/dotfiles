import { nodeFiles } from "../src/node-files.ts";
import {
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, it } from "vitest";
import { PlanStore } from "../src/store.ts";

const directories: string[] = [];
afterEach(() => {
  for (const directory of directories.splice(0)) {
    rmSync(directory, { recursive: true, force: true });
  }
});

function fixture(session = "session-a") {
  const directory = mkdtempSync(join(tmpdir(), "pi-plan-store-"));
  directories.push(directory);
  return {
    directory,
    store: new PlanStore(join(directory, "plans"), session, nodeFiles),
  };
}

it.each(["unwritten", "deleted"])(
  "requests a replacement for a missing plan (%s)",
  (state) => {
    const { directory, store } = fixture();

    if (state === "deleted") {
      store.write("# Original plan\n");
      rmSync(store.path);
    }

    expect(() => store.read()).toThrow(
      `The active plan is missing. Write a new implementation plan to ${store.path} before requesting approval.`,
    );
    expect(store.permitsWrite(store.path, directory)).toBe(true);

    const replacement = store.write("# Replacement plan\n");
    expect(store.read()).toStrictEqual(replacement);
  },
);

it("binds approval to the displayed document revision", () => {
  const { store } = fixture();
  store.write("First plan\n");
  const presented = store.read();
  expect(store.matches(presented)).toBe(true);
  writeFileSync(store.path, "Revised by an external editor\n");
  expect(store.matches(presented)).toBe(false);
  expect(store.read().content).toBe("Revised by an external editor\n");
});

it("permits writes only to the active document and refuses symlinks", () => {
  const { directory, store } = fixture();
  store.write("Plan\n");
  const outside = join(directory, "outside.md");
  writeFileSync(outside, "Keep\n");
  expect(store.permitsWrite(store.path, directory)).toBe(true);
  expect(store.permitsWrite(outside, directory)).toBe(false);
  rmSync(store.path);
  symlinkSync(outside, store.path);
  expect(store.permitsWrite(store.path, directory)).toBe(false);
  expect(() => store.write("Changed\n")).toThrow(
    "Cannot replace a plan through a symlink or an unexpected path.",
  );
  expect(readFileSync(outside, "utf8")).toBe("Keep\n");
});

it("keeps session paths contained even when session IDs contain path syntax", () => {
  const { directory, store } = fixture("../../outside");
  store.write("Contained\n");
  expect(
    store.path.startsWith(realpathSync(join(directory, "plans")) + "/"),
  ).toBe(true);
  expect(store.path.endsWith(".md")).toBe(true);
});
