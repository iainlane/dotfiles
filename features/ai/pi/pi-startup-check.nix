{modelCatalog}: {
  inputs,
  pkgs,
  system,
  ...
}: let
  inherit (pkgs) lib;
  piArgs = {
    inherit pkgs inputs system modelCatalog;
    lib = lib.extend (self: _: {
      hm.dag = import (inputs.home-manager + "/modules/lib/dag.nix") {lib = self;};
    });
    config = {
      catppuccin = {
        accent = "blue";
        flavor = "mocha";
      };
      dotfiles.ai = {
        mcpServers = {};
        proseLint.enable = true;
      };
    };
    defaultModels = modelCatalog.defaults;
    instructions.concatenated = "";
    mcp.wrapWithTools = {package, ...}: package;
  };
  piConfig = import ./home-manager.nix piArgs;
  promptConfig = import ./home-manager.nix (piArgs
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
        name = "anthropic-auth:status";
        source = "extension";
      }
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
  webSearchSettings = builtins.fromJSON piConfig.home.file.".pi/agent/web-search.json".text;
  pi = builtins.head piConfig.home.packages;
  codexAuth = pkgs.writeText "pi-test-auth.json" (builtins.toJSON {
    openai-codex = {
      type = "oauth";
      access = "fixture";
      refresh = "fixture";
      expires = 4102444800000;
      accountId = "fixture";
    };
  });
  # Pi's HOST_PROVIDED_EXTENSION_PACKAGES. An installed copy of one of these
  # modules can bypass Pi's extension loader.
  hostProvidedModules = [
    "@earendil-works/pi-agent-core"
    "@earendil-works/pi-ai"
    "@earendil-works/pi-coding-agent"
    "@earendil-works/pi-tui"
    "@mariozechner/pi-agent-core"
    "@mariozechner/pi-ai"
    "@mariozechner/pi-coding-agent"
    "@mariozechner/pi-tui"
    "@sinclair/typebox"
    "typebox"
  ];
  allHomeFiles = piConfig.home.file // lib.mapAttrs' (path: file: lib.nameValuePair ".config/${path}" file) piConfig.xdg.configFile;
  installHomeFiles = lib.concatStringsSep "\n" (lib.mapAttrsToList (path: file: ''
      mkdir -p "$HOME/"${lib.escapeShellArg (dirOf path)}
      ln -s ${file.source or (pkgs.writeText (baseNameOf path) file.text)} "$HOME/"${lib.escapeShellArg path}
    '')
    allHomeFiles);
  webAccessRoot = "${pkgs.pi-web-access}/${pkgs.pi-web-access.packageRoot}";
  subagentsRoot = "${pkgs.pi-subagents}/${pkgs.pi-subagents.packageRoot}";
  planModeRoot = "${pkgs.pi-plan-mode}/${pkgs.pi-plan-mode.packageRoot}";
  roleProbe = pkgs.writeText "pi-role-probe.ts" ''
    import assert from "node:assert/strict";
    import { writeFileSync } from "node:fs";
    import { discoverAgents } from "${subagentsRoot}/src/agents/agents.ts";
    import { readPlanModeSettings } from "${planModeRoot}/src/settings.ts";

    export default function (pi) {
      pi.on("session_start", async () => {
        const planningTools = [
          "read", "bash", "grep", "find", "ls", "codemode", "plan_explore",
          "ast_grep_search", "ast_grep_outline", "web_search", "fetch_content",
          "get_search_content", "source_check",
        ].sort();
        assert.deepStrictEqual(pi.getActiveTools().filter(name => planningTools.includes(name)).sort(), planningTools);
        const loaded = await readPlanModeSettings();
        assert.equal(loaded.kind, "loaded");
        assert.deepStrictEqual(loaded.settings, {
          thinkingLevel: "high",
          defaultPlanTools: [
            "read", "bash", "grep", "find", "ls", "codemode", "project_report",
            "symbol_search", "module_report", "read_symbol", "read_enclosing",
            "effective_config", "lens_diagnostics", "ast_grep_search", "ast_grep_outline",
            "web_search", "fetch_content", "get_search_content", "source_check", "plan_explore",
          ],
        });
        assert.ok(pi.getCommands().some(command => command.name === "footer"));
        assert.ok(pi.getCommands().some(command => command.name === "pr"));
        assert.ok(pi.getCommands().some(command => command.name === "ultrafast"));
        assert.ok(pi.getAllTools().some(tool => tool.name === "edit"));
        assert.ok(pi.getAllTools().some(tool => tool.name === "write"));
        assert.ok(!pi.getAllTools().some(tool => tool.name === "apply_patch"));
        const roles = provider => discoverAgents(process.cwd(), "user", provider, { globalNpmRoot: null }).agents
          .filter(agent => ["reviewer", "researcher"].includes(agent.name))
          .map(({ name, model, thinking, tools, subagentOnlyExtensions }) => ({ name, model, thinking, tools, subagentOnlyExtensions }))
          .sort((a, b) => a.name.localeCompare(b.name));
        const expected = [
          {
            name: "researcher",
            model: "openai-codex/${modelCatalog.openai.sol}",
            thinking: "medium",
            tools: ["read", "write", "web_search", "fetch_content", "get_search_content", "source_check", "codemode"],
            subagentOnlyExtensions: ["~/.pi/agent/packages/pi-web-access"],
          },
          {
            name: "reviewer",
            model: "openai-codex/${modelCatalog.openai.sol}",
            thinking: "high",
            tools: ["read", "grep", "find", "ls", "watchdog_diff", "contact_supervisor"],
            subagentOnlyExtensions: undefined,
          },
        ];
        assert.deepStrictEqual(roles("openai-codex"), expected);
        assert.deepStrictEqual(roles("anthropic"), expected.map(role => ({ ...role, model: undefined })));
        writeFileSync("role-probe-ok", "");
      });
    }
  '';
  liveModelsProbe = pkgs.writeText "pi-live-models-probe.ts" ''
    import assert from "node:assert/strict";
    import { writeFileSync } from "node:fs";

    export default function (pi) {
      pi.on("session_start", async (_, ctx) => {
        const originalFetch = globalThis.fetch;
        const requests = [];
        const alias = {
          type: "chat",
          id: "~openai/gpt-test-sol-latest",
          name: "Sol Latest",
          provider: "openrouter",
          api: "openai-completions",
          baseUrl: "https://openrouter.ai/api/v1",
          reasoning: false,
          input: ["text"],
          contextWindow: 128000,
          maxTokens: 4096,
          cost: { input: 1, output: 2, cacheRead: 0, cacheWrite: 0 },
        };
        globalThis.fetch = async (url, options) => {
          const address = String(url);
          requests.push(address);
          if (address.startsWith("https://pi.dev/api/models/providers/openrouter")) {
            return Response.json([alias], { headers: { "last-modified": "Fri, 01 Jan 2100 00:00:00 GMT" } });
          }
          if (address === "https://openrouter.ai/api/v1/models/user") {
            return new Response(null, { status: 404 });
          }
          assert.equal(address, "https://openrouter.ai/api/v1/models");
          assert.equal(options.headers.Authorization, "Bearer openrouter-fixture");
          return Response.json({ data: [{
            id: "deepseek/deepseek-v4.1-flash-1017",
            name: "DeepSeek: DeepSeek V4.1 Flash 1017",
            context_length: 1048576,
            architecture: { input_modalities: ["text", "image"], output_modalities: ["text"] },
            top_provider: { max_completion_tokens: 393216 },
            pricing: { prompt: "0.00000015", completion: "0.0000006", input_cache_read: "0.000000003" },
            reasoning: { mandatory: false, supported_efforts: ["max", "high", "low", "none"] },
          }] });
        };

        try {
          const offline = await ctx.modelRegistry.refresh({ providers: ["openrouter"], allowNetwork: false });
          assert.deepStrictEqual([...offline.errors], []);
          assert.deepStrictEqual(requests, []);

          const result = await ctx.modelRegistry.refresh({ providers: ["openrouter"], allowNetwork: true, force: true });
          assert.deepStrictEqual([...result.errors], []);
          assert.ok(requests.includes("https://openrouter.ai/api/v1/models"));
          const { type, ...aliasConfig } = alias;
          assert.deepStrictEqual(ctx.modelRegistry.find("openrouter", alias.id), {
            ...aliasConfig, headers: undefined, ctxSource: "static", maxSource: "static",
          });
          const model = ctx.modelRegistry.find("openrouter", "deepseek/deepseek-v4.1-flash-1017");
          assert.deepStrictEqual(model, {
            id: "deepseek/deepseek-v4.1-flash-1017",
            name: "DeepSeek: DeepSeek V4.1 Flash 1017",
            provider: "openrouter",
            api: "openai-completions",
            baseUrl: "https://openrouter.ai/api/v1",
            reasoning: true,
            input: ["text", "image"],
            contextWindow: 1048576,
            maxTokens: 393216,
            headers: undefined,
            ctxSource: "live",
            maxSource: "live",
            cost: { input: 0.15, output: 0.6, cacheRead: 0.003, cacheWrite: 0 },
            thinkingLevelMap: { off: "none", minimal: null, low: "low", medium: null, high: "high", xhigh: null, max: "max" },
            compat: {
              supportsDeveloperRole: false,
              thinkingFormat: "openrouter",
              supportsStrictMode: true,
              sendSessionAffinityHeaders: true,
              requiresReasoningContentOnAssistantMessages: true,
            },
          });
          requests.length = 0;
          const restored = await ctx.modelRegistry.refresh({ providers: ["openrouter"], allowNetwork: false });
          assert.deepStrictEqual([...restored.errors], []);
          assert.deepStrictEqual(requests, []);
          assert.deepStrictEqual(ctx.modelRegistry.find("openrouter", model.id), model);
          writeFileSync("live-models-probe-ok", "");
        } finally {
          globalThis.fetch = originalFetch;
        }
      });
    }
  '';
  startupProbe = pkgs.writeText "pi-startup-probe.ts" ''
    import assert from "node:assert/strict";
    import { writeFileSync } from "node:fs";
    import { parseFrontmatter } from "@earendil-works/pi-coding-agent";
    import { findModelWithProviderRouting } from "${webAccessRoot}/summary-model-scope.ts";

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

      const routedSol = {
        provider: "openrouter",
        id: "openai/${modelCatalog.openai.sol}",
      };
      assert.deepStrictEqual(
        findModelWithProviderRouting({
          find: () => undefined,
          getAvailable: () => [routedSol],
        }, "openai", "${modelCatalog.openai.sol}"),
        routedSol,
      );
      writeFileSync("startup-probe-ok", "");
    }
  '';
  testSettings = pkgs.writeText "pi-test-settings.json" (builtins.toJSON {
    extensions = ["${startupProbe}"];
    packages = [
      "${pkgs.pi-anthropic-auth}/${pkgs.pi-anthropic-auth.packageRoot}"
      "${pkgs.pi-prompt-template-model}/${pkgs.pi-prompt-template-model.packageRoot}"
    ];
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
  pi-startup = pkgs.runCommandLocal "pi-startup" {} ''
    export HOME="$TMPDIR/home"
    export PI_CODING_AGENT_DIR="$HOME/.pi/agent"
    export PI_OFFLINE=1
    mkdir -p "$PI_CODING_AGENT_DIR"
    cp ${testSettings} "$PI_CODING_AGENT_DIR/settings.json"
    cp ${pkgs.writeText "web-search.json" (builtins.toJSON webSearchSettings)} "$PI_CODING_AGENT_DIR/web-search.json"
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (path: text: ''
        install -Dm644 ${pkgs.writeText (baseNameOf path) text} "$HOME/"${lib.escapeShellArg path}
      '')
      prompts)}
    install -Dm644 ${plainPrompt} "$PI_CODING_AGENT_DIR/prompts/plain-fixture.md"
    ${pkgs.jq}/bin/jq --sort-keys 'sort_by(.name)' ${expectedCommands} >expected-commands.json
    test ${lib.escapeShellArg webSearchSettings.fetch.answerProvider} = openai
    test ${lib.escapeShellArg webSearchSettings.fetch.answerModel} = ${lib.escapeShellArg modelCatalog.openai.sol}

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

    export HOME="$TMPDIR/configured-home"
    export PI_CODING_AGENT_DIR="$HOME/.pi/agent"
    ${installHomeFiles}
    export DRY_RUN_CMD=""
    ${piConfig.home.activation.piPlanModeSettings.data}
    test ! -L "$PI_CODING_AGENT_DIR/pi-plan-mode.json"
    cp "$PI_CODING_AGENT_DIR/pi-plan-mode.json" plan-defaults.json
    printf '%s\n' '{"thinkingLevel":"high","futureSetting":true,"defaultPlanTools":[]}' >saved-plan-settings.json
    ln -sf "$PWD/saved-plan-settings.json" "$PI_CODING_AGENT_DIR/pi-plan-mode.json"
    ${piConfig.home.activation.piPlanModeSettings.data}
    test ! -L "$PI_CODING_AGENT_DIR/pi-plan-mode.json"
    ${pkgs.jq}/bin/jq --sort-keys '. + {thinkingLevel: "high", futureSetting: true}' plan-defaults.json >expected-plan-settings.json
    ${pkgs.jq}/bin/jq --sort-keys . "$PI_CODING_AGENT_DIR/pi-plan-mode.json" >actual-plan-settings.json
    diff -u expected-plan-settings.json actual-plan-settings.json
    ${piConfig.home.activation.piPlanModeSettings.data}
    ${pkgs.jq}/bin/jq --sort-keys . "$PI_CODING_AGENT_DIR/pi-plan-mode.json" >actual-plan-settings.json
    diff -u expected-plan-settings.json actual-plan-settings.json
    cp "$PI_CODING_AGENT_DIR/pi-plan-mode.json" valid-plan-settings.json
    for invalid in '{invalid' '{} {}' '[]'; do
      printf '%s\n' "$invalid" >"$PI_CODING_AGENT_DIR/pi-plan-mode.json"
      if ( ${piConfig.home.activation.piPlanModeSettings.data} ); then
        echo 'Invalid plan settings must not be overwritten' >&2
        exit 1
      fi
      printf '%s\n' "$invalid" >invalid-plan-settings.json
      cmp invalid-plan-settings.json "$PI_CODING_AGENT_DIR/pi-plan-mode.json"
    done
    rm "$PI_CODING_AGENT_DIR/pi-plan-mode.json"
    mkfifo "$PI_CODING_AGENT_DIR/pi-plan-mode.json"
    status=0
    ${pkgs.coreutils}/bin/timeout 5 ${pkgs.bash}/bin/bash -c ${lib.escapeShellArg piConfig.home.activation.piPlanModeSettings.data} || status=$?
    test "$status" -ne 0
    test "$status" -ne 124
    test -p "$PI_CODING_AGENT_DIR/pi-plan-mode.json"
    rm "$PI_CODING_AGENT_DIR/pi-plan-mode.json"
    cp valid-plan-settings.json "$PI_CODING_AGENT_DIR/pi-plan-mode.json"
    install -m600 ${codexAuth} "$PI_CODING_AGENT_DIR/auth.json"
    ${pkgs.jq}/bin/jq '.openrouter = {type: "api_key", key: "openrouter-fixture"}' \
      "$PI_CODING_AGENT_DIR/auth.json" >auth.json
    mv auth.json "$PI_CODING_AGENT_DIR/auth.json"
    find -L "$PI_CODING_AGENT_DIR/packages" \( ${lib.concatMapStringsSep " -o " (module: "-path ${lib.escapeShellArg "*/node_modules/${module}"}") hostProvidedModules} \) -print >host-provided-copies.txt
    if [[ -s host-provided-copies.txt ]]; then
      cat host-provided-copies.txt >&2
      exit 1
    fi
    if ! printf '%s\n' '{"type":"get_state"}' | ${lib.getExe pi} \
      --mode rpc --no-session --no-context-files -e ${roleProbe} -e ${liveModelsProbe} >responses.jsonl 2>errors.txt; then
      cat errors.txt responses.jsonl >&2
      exit 1
    fi
    if [[ -s errors.txt || ! -f role-probe-ok || ! -f live-models-probe-ok ]]; then
      cat errors.txt responses.jsonl >&2
      exit 1
    fi
    ${pkgs.jq}/bin/jq --exit-status --slurp '
      [.[] | select(.command == "get_state") | .data.model | "\(.provider)/\(.id)"]
        == ["openai-codex/${modelCatalog.defaults.openai}"]
    ' responses.jsonl >/dev/null || { cat responses.jsonl >&2; exit 1; }

    touch "$out"
  '';
}
