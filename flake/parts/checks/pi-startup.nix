{inputs, ...}: {
  perSystem = {
    pkgs,
    system,
    ...
  }: let
    inherit (pkgs) lib;
    modelCatalog = import ../../../features/ai/models.nix;
    piArgs = {
      inherit pkgs inputs lib system modelCatalog;
      config.catppuccin = {
        accent = "blue";
        flavor = "mocha";
      };
      defaultModels = modelCatalog.defaults;
      instructions.concatenated = "";
      mcp.wrapWithTools = {package, ...}: package;
    };
    piConfig = import ../../../features/ai/pi/home-manager.nix piArgs;
    promptConfig = import ../../../features/ai/pi/home-manager.nix (piArgs
      // {
        modelCatalog = {
          openai.sol = "gpt-test-sol";
          openrouter.sol = "~openai/gpt-test-sol-latest";
        };
      });
    prompts =
      lib.mapAttrs (_: file: file.text)
      (lib.filterAttrs (path: _: lib.hasPrefix ".pi/agent/prompts/" path) promptConfig.home.file);
    expectedCommands = pkgs.writeText "expected-prompt-commands.json" (builtins.toJSON (
      lib.mapAttrsToList (path: _: {
        name = lib.removeSuffix ".md" (baseNameOf path);
        source = "extension";
      })
      prompts
      ++ [
        {
          name = "plain-fixture";
          source = "prompt";
        }
      ]
    ));
    plainPrompt = pkgs.writeText "plain-fixture.md" ''
      ---
      description: Plain prompt fixture
      ---
      A plain prompt.
    '';
    settings = builtins.fromJSON piConfig.home.file.".pi/agent/settings.json".text;
    pi = builtins.head piConfig.home.packages;
    startupProbe = pkgs.writeText "pi-startup-probe.ts" ''
      import assert from "node:assert/strict";
      import { writeFileSync } from "node:fs";
      import { parseFrontmatter } from "@earendil-works/pi-coding-agent";

      export default function () {
        const prompts = ${builtins.toJSON prompts};
        assert.notDeepStrictEqual(prompts, {});
        const actual = Object.fromEntries(Object.entries(prompts).map(([path, text]) => [
          path, parseFrontmatter(text).frontmatter.model,
        ]));
        const expected = Object.fromEntries(Object.keys(prompts).map(path => [
          path, "gpt-test-sol, openrouter/~openai/gpt-test-sol-latest",
        ]));
        assert.deepStrictEqual(actual, expected);
        writeFileSync("startup-probe-ok", "");
      }
    '';
    testSettings = pkgs.writeText "pi-test-settings.json" (builtins.toJSON {
      inherit (settings) enabledModels;
      extensions = ["${startupProbe}"];
      packages = ["${pkgs.pi-prompt-template-model}/${pkgs.pi-prompt-template-model.packageRoot}"];
      prompts = settings.prompts or [];
    });
    modelIds = [
      "claude-fable-test"
      "claude-opus-test"
      "claude-sonnet-test"
      "claude-haiku-test"
      "gpt-test"
    ];
    modelsFile = prefix:
      pkgs.writeText "pi-test-models.json" (builtins.toJSON {
        providers.fixture = {
          baseUrl = "http://127.0.0.1:1/v1";
          api = "openai-completions";
          apiKey = "fixture";
          models = map (id: {id = prefix + id;}) modelIds;
        };
      });
  in {
    checks.pi-startup = pkgs.runCommandLocal "pi-startup" {} ''
      export HOME="$TMPDIR/home"
      export PI_CODING_AGENT_DIR="$HOME/.pi/agent"
      export PI_OFFLINE=1
      mkdir -p "$PI_CODING_AGENT_DIR"
      cp ${testSettings} "$PI_CODING_AGENT_DIR/settings.json"
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (path: text: ''
          install -Dm644 ${pkgs.writeText (baseNameOf path) text} "$HOME/"${lib.escapeShellArg path}
        '')
        prompts)}
      install -Dm644 ${plainPrompt} "$PI_CODING_AGENT_DIR/prompts/plain-fixture.md"
      ${pkgs.jq}/bin/jq --sort-keys 'sort_by(.name)' ${expectedCommands} >expected-commands.json

      for models in ${modelsFile ""} ${modelsFile "vendor/"}; do
        rm -f startup-probe-ok
        install -m644 "$models" "$PI_CODING_AGENT_DIR/models.json"
        if ! printf '%s\n' '{"type":"get_state"}' '{"type":"get_commands"}' | ${lib.getExe pi} \
          --mode rpc --no-session --no-context-files >responses.jsonl 2>errors.txt; then
          cat errors.txt responses.jsonl >&2
          exit 1
        fi
        if [[ -s errors.txt || ! -f startup-probe-ok ]]; then
          cat errors.txt responses.jsonl >&2
          exit 1
        fi
        ${pkgs.jq}/bin/jq --exit-status --slurp '
          [.[] | select(.command == "get_state")
            | .type == "response" and .success and .data.model.provider == "fixture"] == [true]
        ' responses.jsonl >/dev/null || { cat responses.jsonl >&2; exit 1; }
        ${pkgs.jq}/bin/jq --slurp --sort-keys --slurpfile expected ${expectedCommands} '
          ($expected[0] | map(.name)) as $names
          | [.[] | select(.command == "get_commands") | .data.commands[]
            | select(.name as $name | $names | index($name))
            | {name, source}]
          | sort_by(.name)
        ' responses.jsonl >commands.json
        diff -u expected-commands.json commands.json
      done

      touch "$out"
    '';
  };
}
