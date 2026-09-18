_: {
  perSystem = {pkgs, ...}: let
    packageRoot = "${pkgs.pi-lens}/${pkgs.pi-lens.packageRoot}";
    probe = pkgs.writeText "pi-lens-lua.mjs" ''
      import assert from "node:assert/strict";
      import { TreeSitterClient } from "${packageRoot}/dist/clients/tree-sitter-client.js";
      import { TreeSitterSymbolExtractor } from "${packageRoot}/dist/clients/tree-sitter-symbol-extractor.js";

      globalThis.fetch = async () => {
        throw new Error("The packaged Lua grammar must work without network access");
      };

      const client = new TreeSitterClient();
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
    checks.pi-lens-lua = pkgs.runCommandLocal "pi-lens-lua" {} ''
      export HOME="$TMPDIR/home"
      mkdir -p "$HOME"
      ${pkgs.nodejs}/bin/node ${probe}
      touch "$out"
    '';
  };
}
