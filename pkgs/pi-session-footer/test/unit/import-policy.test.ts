import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { afterAll, expect, it } from "vitest";
import { record } from "#footer/shared/text.ts";

const directory = mkdtempSync(join(tmpdir(), "footer-import-policy-"));
const lint = fileURLToPath(
  new URL("./bin/oxlint", import.meta.resolve("oxlint/package.json")),
);

const config = fileURLToPath(
  new URL("../../../../.oxlintrc.json", import.meta.url),
);

const rejected = join(directory, "rejected.ts");

afterAll(() => rmSync(directory, { recursive: true, force: true }));

/**
 * Lints `path` and returns the exit status and the diagnostics of the
 * parent-relative import rule, without the text that oxlint writes for them.
 */
function parentImports(path: string): unknown {
  const result = spawnSync(
    process.execPath,
    [lint, "-c", config, "-f", "json", path],
    { encoding: "utf8" },
  );
  const report: unknown = JSON.parse(result.stdout);

  if (!record(report) || !Array.isArray(report.diagnostics)) {
    throw new Error(`Unexpected oxlint output: ${result.stdout}`);
  }

  return {
    status: result.status,
    diagnostics: report.diagnostics
      .filter(
        (diagnostic: unknown) =>
          record(diagnostic) &&
          diagnostic.code === "import(no-relative-parent-imports)",
      )
      .map((diagnostic: Record<string, unknown>) => ({
        code: diagnostic.code,
        severity: diagnostic.severity,
        filename: diagnostic.filename,
        labels: diagnostic.labels,
      })),
  };
}

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
  writeFileSync(rejected, source);
  const specifier = /"[^"]*outside\.ts"/u.exec(source)?.[0] ?? "";
  const offset = source.indexOf(specifier);

  expect(parentImports(rejected)).toStrictEqual({
    status: 1,
    diagnostics: [
      {
        code: "import(no-relative-parent-imports)",
        severity: "error",
        filename: rejected,
        labels: [
          {
            span: {
              offset,
              length: specifier.length,
              line: 1,
              column: offset + 1,
            },
          },
        ],
      },
    ],
  });
});

it.each(["./nearby.ts", "#footer/domain/usage.ts"])(
  "accepts the module path %s",
  (specifier) => {
    const path = join(directory, "accepted.ts");
    writeFileSync(path, `export * from ${JSON.stringify(specifier)};`);

    expect(parentImports(path)).toStrictEqual({ status: 0, diagnostics: [] });
  },
);
