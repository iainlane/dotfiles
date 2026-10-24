import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile, readdir } from "node:fs/promises";
import { pathToFileURL } from "node:url";

interface TreeSitterClient {
  init(): Promise<boolean>;
  isLanguageSupported(language: string): Promise<boolean>;
  withParsedTree(
    filePath: string,
    language: string,
    content: string,
    extract: (tree: { rootNode: { hasError: boolean } }) => unknown,
  ): Promise<unknown>;
}

interface SymbolExtractor {
  init(): Promise<boolean>;
  extract(tree: unknown, filePath: string, content: string): unknown;
}

interface LensExports {
  getSharedTreeSitterClient(): TreeSitterClient;
  TreeSitterSymbolExtractor: new (
    language: string,
    client: TreeSitterClient,
  ) => SymbolExtractor;
}

const packageRoot = process.argv[2];

if (!packageRoot) {
  throw new Error("Pass the installed Pi Lens package directory");
}

globalThis.fetch = async () => {
  throw new Error("Packaged grammars must work without network access");
};

async function loadExport<Name extends keyof LensExports>(
  name: Name,
): Promise<LensExports[Name]> {
  for (const entry of await readdir(`${packageRoot}/dist`)) {
    if (!entry.startsWith("chunk-") || !entry.endsWith(".js")) continue;

    const filename = `${packageRoot}/dist/${entry}`;
    const source = await readFile(filename, "utf8");
    const exports = source.match(/export \{([^}]+)\};/)?.[1] ?? "";
    if (!exports.split(",").some((value) => value.trim() === name)) continue;

    const module: LensExports = await import(pathToFileURL(filename).href);
    return module[name];
  }

  throw new Error("Pi Lens does not export " + name);
}

const getSharedTreeSitterClient = await loadExport("getSharedTreeSitterClient");
const TreeSitterSymbolExtractor = await loadExport("TreeSitterSymbolExtractor");
const client = getSharedTreeSitterClient();
assert.equal(await client.init(), true);
const manifest: {
  grammars: Record<string, string>;
  vendored: Record<string, { sha256: string }>;
} = JSON.parse(
  await readFile(`${packageRoot}/scripts/grammars.lock.json`, "utf8"),
);
for (const [filename, digest] of Object.entries(manifest.grammars)) {
  const bytes = await readFile(`${packageRoot}/grammars/${filename}`);
  assert.equal(
    `sha256:${createHash("sha256").update(bytes).digest("hex")}`,
    digest,
    filename,
  );
  const sidecar = JSON.parse(
    await readFile(`${packageRoot}/grammars/${filename}.json`, "utf8"),
  );
  assert.equal(sidecar.sha256, digest, filename);
}
for (const [filename, metadata] of Object.entries(manifest.vendored)) {
  const bytes = await readFile(`${packageRoot}/vendor/grammars/${filename}`);
  assert.equal(
    `sha256:${createHash("sha256").update(bytes).digest("hex")}`,
    metadata.sha256,
    filename,
  );
}

const samples: Record<string, string> = {
  bash: "echo hello\n",
  c: "int answer(void) { return 42; }",
  cpp: "int answer() { return 42; }",
  csharp: "class Example {}",
  css: "body { display: block; }",
  dart: "int answer() => 42;",
  elixir: "defmodule Example do\nend",
  go: "package example\nfunc answer() int { return 42 }",
  html: "<p>Hello</p>",
  java: "class Example {}",
  javascript: "function answer() { return 42; }",
  json: '{"answer":42}',
  kotlin: "fun answer() = 42",
  lua: "local answer = 42",
  ocaml: "let answer = 42",
  php: "<?php function answer() { return 42; }",
  python: "def answer():\n    return 42\n",
  ruby: "def answer\n42\nend",
  rust: "fn answer() -> i32 { 42 }",
  swift: "func answer() -> Int { return 42 }",
  toml: "answer = 42",
  tsx: "const answer = <p>Hello</p>;",
  typescript: "const answer: number = 42;",
  vue: "<template><p>Hello</p></template>",
  yaml: "answer: 42\n",
  zig: "const answer = 42;",
  cue: "answer: 42",
};
for (const [language, source] of Object.entries(samples)) {
  const blocked =
    language === "swift" &&
    !process.versions.bun &&
    Number(process.versions.node.split(".")[0]) >= 24;
  assert.equal(await client.isLanguageSupported(language), !blocked, language);
  if (blocked) continue;
  const parsed = await client.withParsedTree(
    `fixture.${language}`,
    language,
    source,
    (tree) => {
      assert.equal(tree.rootNode.hasError, false, language);
      return true;
    },
  );
  assert.deepStrictEqual(parsed, { parsed: true, value: true }, language);
}
const extractor = new TreeSitterSymbolExtractor("lua", client);
assert.equal(await extractor.init(), true);
const content = "local function answer()\n  return 42\nend\n";
const result = await client.withParsedTree(
  "fixture.lua",
  "lua",
  content,
  (tree) => extractor.extract(tree, "fixture.lua", content),
);
assert.deepStrictEqual(result, {
  parsed: true,
  value: {
    symbols: [
      {
        id: "fixture.lua:answer",
        name: "answer",
        kind: "function",
        filePath: "fixture.lua",
        line: 1,
        endLine: 3,
        column: 1,
        signature: undefined,
        isExported: false,
      },
    ],
    refs: [],
    imports: [],
    coverage: {
      definitions: "complete",
      references: "complete",
      imports: "complete",
    },
  },
});
