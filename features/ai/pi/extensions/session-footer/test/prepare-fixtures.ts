import { cpSync, mkdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
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

  execFileSync("patch", ["--batch", "-p1", "-i", patch], {
    cwd: target,
    stdio: "inherit",
  });
}
