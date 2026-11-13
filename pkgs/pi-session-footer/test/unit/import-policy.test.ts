import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { afterAll, expect, it } from "vitest";

const directory = mkdtempSync(join(tmpdir(), "footer-import-policy-"));
const lint = fileURLToPath(
  new URL("./bin/oxlint", import.meta.resolve("oxlint/package.json")),
);

const config = fileURLToPath(
  new URL("../../../../.oxlintrc.json", import.meta.url),
);

afterAll(() => rmSync(directory, { recursive: true, force: true }));

function readDocument(file: string): unknown {
  return JSON.parse(
    readFileSync(new URL(`../../${file}`, import.meta.url), "utf8"),
  );
}

it("uses matching runtime and compiler aliases", () => {
  const imports = {
    "#footer/*": "./src/*",
    "#test/*": "./test/*",
    "#demo/*": "./demo/*",
    "#scripts/*": "./scripts/*",
    "#fixtures/*": "./.fixtures/*",
    "#footer-entry": "./index.ts",
  };
  const paths = Object.fromEntries(
    Object.entries(imports).map(([alias, target]): [string, string[]] => [
      alias,
      [target],
    ]),
  );

  expect(readDocument("package.json")).toHaveProperty("imports", imports);
  expect(readDocument("tsconfig.json")).toHaveProperty(
    "compilerOptions.paths",
    paths,
  );
  expect(readDocument("tsconfig.source.json")).toStrictEqual({
    extends: "./tsconfig.json",
    include: ["index.ts", "src/**/*.ts"],
  });
});

it("includes the Vitest configuration in strict checking", () => {
  expect(readDocument("tsconfig.json")).toHaveProperty("include", [
    "index.ts",
    "src/**/*.ts",
    "test/**/*.ts",
    "demo/**/*.ts",
    "scripts/**/*.ts",
    "vitest.config.ts",
  ]);
});

it.each([
  'import { value } from "../outside.ts"; console.log(value);',
  'import type { Value } from "../outside.ts"; export type Result = Value;',
  'export * from "../outside.ts";',
  'const value = await import("../outside.ts"); console.log(value);',
  'const value = require("../outside.ts"); console.log(value);',
  'export * from "./../outside.ts";',
])("rejects parent-relative module imports: %s", (source) => {
  const path = join(directory, "rejected.ts");
  writeFileSync(path, source);
  const result = spawnSync(process.execPath, [lint, "-c", config, path], {
    encoding: "utf8",
  });

  const diagnostic: unknown = expect.stringContaining(
    "no-relative-parent-imports",
  );
  expect({
    status: result.status,
    diagnostic: result.stdout + result.stderr,
  }).toStrictEqual({ status: 1, diagnostic });
});

it.each(["./nearby.ts", "#footer/domain/usage.ts"])(
  "accepts the module path %s",
  (specifier) => {
    const path = join(directory, "accepted.ts");
    writeFileSync(path, `export * from ${JSON.stringify(specifier)};`);

    expect(
      execFileSync(process.execPath, [lint, "-c", config, path], {
        encoding: "utf8",
      }),
    ).not.toContain("no-relative-parent-imports");
  },
);
