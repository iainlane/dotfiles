import {
  cpSync,
  mkdirSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { execFileSync } from "node:child_process";
import { basename, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));

for (const [name, dependency] of [
  ["pi-sub-core", "@marckrenn/pi-sub-core"],
  ["rpiv-todo", "@juicesharp/rpiv-todo"],
  ["rpiv-btw", "@juicesharp/rpiv-btw"],
] as const) {
  const target = join(root, ".fixtures", name);

  rmSync(target, { recursive: true, force: true });
  mkdirSync(target, { recursive: true });
  cpSync(join(root, "node_modules", dependency), target, {
    recursive: true,
    filter: (path) =>
      !path.includes(`${dependency}/node_modules`) && basename(path) !== "test",
  });
  // The installed packages can be read-only, as in the Nix store, and the
  // copy keeps their modes. The fixture edits its copy below.
  execFileSync("chmod", ["-R", "u+w", target]);
  symlinkSync(resolve(root, "node_modules"), join(target, "node_modules"));
  writeFileSync(
    join(target, "tsconfig.json"),
    '{ "extends": "../../tsconfig.json" }',
  );

  if (name === "pi-sub-core") {
    const path = join(target, "index.ts");
    const source = readFileSync(path, "utf8");
    const end = source.lastIndexOf("\n}");
    if (end < 0) {
      throw new Error("Cannot add the quota fixture's idle probe.");
    }
    writeFileSync(
      path,
      `${source.slice(0, end)}\n\tfixtureIdle.set(pi, () => scope.running ?? Promise.resolve());${source.slice(end)}\nexport const fixtureIdle = new WeakMap<ExtensionAPI, () => Promise<void>>();\n`,
    );
  }
}
