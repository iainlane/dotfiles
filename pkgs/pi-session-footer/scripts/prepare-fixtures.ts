import {
  cpSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { execFileSync } from "node:child_process";
import { basename, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

class IdleProbeInsertionError extends Error {
  readonly path: string;

  constructor(path: string) {
    super(`Cannot find the end of the quota fixture's extension in ${path}`);
    this.name = "IdleProbeInsertionError";
    this.path = path;
  }
}

const root = fileURLToPath(new URL("../", import.meta.url));

for (const [name, dependency] of [
  ["pi-sub-core", "@marckrenn/pi-sub-core"],
  ["rpiv-btw", "@juicesharp/rpiv-btw"],
] as const) {
  const target = join(root, ".fixtures", name);
  const sourceDirectory = dirname(
    realpathSync(
      fileURLToPath(import.meta.resolve(`${dependency}/package.json`)),
    ),
  );
  const context = dependency.startsWith("@")
    ? dirname(dirname(sourceDirectory))
    : dirname(sourceDirectory);

  rmSync(target, { recursive: true, force: true });
  mkdirSync(target, { recursive: true });
  cpSync(sourceDirectory, target, {
    recursive: true,
    filter: (path) =>
      basename(path) !== "node_modules" && basename(path) !== "test",
  });
  // The installed packages can be read-only, as in the Nix store, and the
  // copy keeps their modes. The fixture edits its copy below.
  execFileSync("chmod", ["-R", "u+w", target]);
  symlinkSync(context, join(target, "node_modules"));
  writeFileSync(
    join(target, "tsconfig.json"),
    '{ "extends": "../../tsconfig.json" }',
  );

  if (name === "pi-sub-core") {
    const path = join(target, "index.ts");
    const source = readFileSync(path, "utf8");
    const end = source.lastIndexOf("\n}");
    if (end < 0) {
      throw new IdleProbeInsertionError(path);
    }
    writeFileSync(
      path,
      `${source.slice(0, end)}\n\tfixtureIdle.set(pi, () => scope.running ?? Promise.resolve());${source.slice(end)}\nexport const fixtureIdle = new WeakMap<ExtensionAPI, () => Promise<void>>();\n`,
    );
  }
}
