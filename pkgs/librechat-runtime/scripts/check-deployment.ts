import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readdir, realpath } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve, sep } from "node:path";

const directory = process.argv[2];

if (directory === undefined) {
  throw new Error("Provide the deployed LibreChat directory.");
}

const root = await realpath(directory);

async function checkLinks(parent: string): Promise<void> {
  const entries = await readdir(parent, { withFileTypes: true });

  await Promise.all(
    entries.map(async (entry) => {
      const file = join(parent, entry.name);

      if (entry.isSymbolicLink()) {
        const target = await realpath(file);
        assert.ok(
          target === root || target.startsWith(root + sep),
          `Dependency link escapes the deployment: ${file}`,
        );
        return;
      }

      if (entry.isDirectory()) {
        await checkLinks(file);
      }
    }),
  );
}

await checkLinks(root);

for (const [cwd, specifier] of [
  [root, "@dotfiles/librechat-runtime/manifest"],
  [
    join(root, "node_modules/@dotfiles/librechat-runtime"),
    "@dotfiles/librechat-code-bridge",
  ],
]) {
  const imported = spawnSync(
    process.execPath,
    [
      "--input-type=module",
      "--eval",
      `await import(${JSON.stringify(specifier)})`,
    ],
    { cwd, encoding: "utf8" },
  );

  assert.equal(imported.status, 0, imported.stderr);
}

for (const program of ["librechat-runtime", "librechatctl"]) {
  for (const args of [[], ["bootstrap", "--help"], ["--version"]]) {
    const result = spawnSync(
      process.execPath,
      [resolve(root, `dist/bin/${program}.js`), ...args],
      {
        cwd: tmpdir(),
        encoding: "utf8",
        env: {
          ...process.env,
          LIBRECHAT_INTERNAL_MANIFEST: "/nonexistent/librechat-deployment.json",
        },
      },
    );
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stderr, "");
    assert.ok(
      result.stdout.includes(program),
      "The command must identify its executable.",
    );
  }
}
