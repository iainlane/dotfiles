import {
  cpSync,
  mkdirSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { basename, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

const root = fileURLToPath(new URL("../", import.meta.url));

for (const [name, dependency] of [
  ["pi-sub-core", "@marckrenn/pi-sub-core"],
  ["rpiv-todo", "@juicesharp/rpiv-todo"],
] as const) {
  const target = join(root, ".fixtures", name);

  rmSync(target, { recursive: true, force: true });
  mkdirSync(target, { recursive: true });
  cpSync(join(root, "node_modules", dependency), target, {
    recursive: true,
    filter: (path) =>
      !path.includes(`${dependency}/node_modules`) && basename(path) !== "test",
  });
  symlinkSync(resolve(root, "node_modules"), join(target, "node_modules"));
  writeFileSync(
    join(target, "tsconfig.json"),
    '{ "extends": "../../tsconfig.json" }',
  );

  const patch =
    name === "pi-sub-core"
      ? (process.env.PI_FOOTER_CORE_PATCH ??
        resolve(root, "../../../../../pkgs/pi-sub-core/reading-metadata.patch"))
      : (process.env.PI_FOOTER_TODO_PATCH ??
        resolve(root, "../../../../../pkgs/rpiv-todo/widget-visibility.patch"));

  const patches =
    name === "pi-sub-core"
      ? [
          patch,
          process.env.PI_FOOTER_CORE_BACKGROUND_PATCH ??
            resolve(
              root,
              "../../../../../pkgs/pi-sub-core/background-refresh.patch",
            ),
          process.env.PI_FOOTER_CORE_CREDENTIAL_PATCH ??
            resolve(
              root,
              "../../../../../pkgs/pi-sub-core/credential-file.patch",
            ),
        ]
      : [patch];
  for (const source of patches) {
    execFileSync("patch", ["--batch", "-p1", "-i", source], {
      cwd: target,
      stdio: "inherit",
    });
  }
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
