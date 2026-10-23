{pkgs, ...}: let
  packageRoot = "${pkgs.pi-lens}/${pkgs.pi-lens.packageRoot}";
  probe = pkgs.writeText "pi-lens-lua.mjs" ''
    import assert from "node:assert/strict";
    import { readFile, readdir } from "node:fs/promises";
    import { pathToFileURL } from "node:url";

    globalThis.fetch = async () => {
      throw new Error("The packaged Lua grammar must work without network access");
    };

    async function loadExport(name) {
      for (const entry of await readdir("${packageRoot}/dist")) {
        if (!entry.startsWith("chunk-") || !entry.endsWith(".js")) continue;

        const filename = "${packageRoot}/dist/" + entry;
        const source = await readFile(filename, "utf8");
        const exports = source.match(/export \{([^}]+)\};/)?.[1] ?? "";
        if (!exports.split(",").some((value) => value.trim() === name)) continue;

        return (await import(pathToFileURL(filename)))[name];
      }

      throw new Error("Pi Lens does not export " + name);
    }

    const getSharedTreeSitterClient = await loadExport("getSharedTreeSitterClient");
    const TreeSitterSymbolExtractor = await loadExport("TreeSitterSymbolExtractor");
    const client = getSharedTreeSitterClient();
    assert.equal(await client.init(), true);
    const extractor = new TreeSitterSymbolExtractor("lua", client);
    assert.equal(await extractor.init(), true);
    const content = "local function answer()\n  return 42\nend\n";
    const result = await client.withParsedTree(
      "fixture.lua", "lua", content,
      (tree) => extractor.extract(tree, "fixture.lua", content),
    );
    assert.deepStrictEqual(result, {
      parsed: true,
      value: {
        symbols: [{
          id: "fixture.lua:answer",
          name: "answer",
          kind: "function",
          filePath: "fixture.lua",
          line: 1,
          endLine: 3,
          column: 1,
          signature: undefined,
          isExported: false,
        }],
        refs: [],
        imports: [],
        coverage: {
          definitions: "complete",
          references: "complete",
          imports: "complete",
        },
      },
    });
  '';
in {
  pi-lens-lua = pkgs.runCommandLocal "pi-lens-lua" {} ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    ${pkgs.nodejs}/bin/node ${probe}
    touch "$out"
  '';
}
