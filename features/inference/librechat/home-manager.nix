{
  config,
  defaultModels,
  modelCatalog,
  hostConfig,
  inputs,
  instructions,
  lib,
  mcp,
  pkgs,
  pkgs-unstable,
  skillTree,
  ...
} @ moduleArgs: let
  cfg = config.dotfiles.inference.librechat;

  native = pkgs-unstable;

  guestSystem = "${hostConfig.arch}-linux";

  discovery = import ../../../lib/discovery.nix {inherit lib;};

  guestPkgs = import inputs.nixpkgs {
    system = guestSystem;
    config.allowUnfree = true;
    overlays = discovery.importNixFiles ../../../overlays {inherit inputs;};
  };

  guestRegistry = import ../../ai/mcp-server-definitions.nix {
    inherit inputs;
    pkgs = guestPkgs;
  };

  bundles = config.dotfiles.ai.bundles;

  unknownBundles = lib.subtractLists (lib.attrNames bundles) cfg.excludeBundles;

  excludedBundles = lib.attrValues (lib.filterAttrs (name: _: lib.elem name cfg.excludeBundles) bundles);

  sharedServers = removeAttrs config.dotfiles.ai.mcpServers (lib.concatMap (bundle: lib.attrNames bundle.mcpServers) excludedBundles);

  sharedSkills = removeAttrs config.dotfiles.ai.skills (lib.concatMap (bundle: lib.attrNames bundle.skills) excludedBundles);

  nativeDefinition = name: server: let
    definition = config.dotfiles.ai.mcpNativeServers.${name} or null;
  in
    if server ? url
    then server // {headerFiles = {};}
    else if definition != null && (server.command or null) == definition.sourceCommand
    then definition
    else null;

  nativeServers = lib.filterAttrs (_: server: server != null) (lib.mapAttrs nativeDefinition sharedServers);

  localNames = lib.subtractLists (lib.attrNames nativeServers) (lib.attrNames sharedServers);

  guestServer = name: let
    server = sharedServers.${name};
    original = mcp.servers.${name} or null;
    linuxServer = guestRegistry.servers.${name} or null;
    customArguments = (server.args or []) != (original.args or []);
    customPaths = lib.any (value: lib.hasInfix "/nix/store/" value || lib.hasInfix config.home.homeDirectory value) (server.args or []);
    credentialEnvironment = lib.any (key: builtins.match ".*(TOKEN|SECRET|PASSWORD|API_KEY|PRIVATE_KEY).*" (lib.toUpper key) != null) (lib.attrNames (server.env or {}));
  in
    cfg.guestMcpServers.${
      name
    } or (assert lib.assertMsg (original != null && linuxServer != null && server.command == original.command && !(customArguments && customPaths) && !credentialEnvironment)
      "Local MCP ${name} needs an explicit Linux guest definition in dotfiles.inference.librechat.guestMcpServers";
        linuxServer
        // {env = server.env or {};}
        // lib.optionalAttrs customArguments {inherit (server) args;}
        // lib.optionalAttrs (name == "playwright") {
          args =
            (
              if customArguments
              then server.args
              else linuxServer.args or []
            )
            ++ ["--proxy-server" "http://10.0.2.100:3128"];
        });

  guestServers = lib.genAttrs localNames guestServer;

  archiveCli = guestPkgs.writeShellScriptBin "agentsview" ''
    exec ${lib.getExe guestPkgs.librechat-runtime} archive "$@"
  '';

  dependencyNames = lib.unique (lib.concatLists (lib.attrValues (lib.filterAttrs (name: _: builtins.hasAttr name sharedSkills) config.dotfiles.ai.skillRuntimeDependencies)));

  runtimePackages = guestPkgs // {agentsview = archiveCli;};

  skillPackages = map (name: lib.attrByPath (lib.splitString "." name) (throw "Unknown LibreChat guest skill dependency: ${name}") runtimePackages) dependencyNames;

  skills = native.runCommand "librechat-skills" {} ''
    mkdir "$out"
    cp -RL ${skillTree {skills = sharedSkills;}}/. "$out/"
  '';

  guest =
    moduleArgs.librechatGuest or (import ./guest-image.nix {
      inherit inputs archiveCli skillPackages skills;
      pkgs = guestPkgs;
      servers = guestServers;
    });

  postgres = native.postgresql_18.withPackages (extensions: [extensions.pgvector]);

  agentsview = native.writeShellScript "librechat-host-archive" ''
    export AGENTSVIEW_DATA_DIR=${lib.escapeShellArg config.dotfiles.agentsview.dataDir}
    exec ${lib.getExe inputs.llm-agents.packages.${hostConfig.system}.agentsview} "$@"
  '';

  hook = native.writeShellScript "librechat-workspace-reminder" ''
    exec ${lib.getExe native.librechat-runtime} hook ${lib.escapeShellArg "${cfg.stateDirectory}/hook.json"}
  '';

  manifest = (native.formats.json {}).generate "librechat-host.json" {
    inherit (cfg) stateDirectory;
    sopsProgram =
      if pkgs.stdenv.hostPlatform.isDarwin && (config.sops.secrets or {}) != {}
      then config.launchd.agents.sops-nix.config.Program
      else null;
    homeDirectory = config.home.homeDirectory;
    hookCommand = toString hook;
    skillsDirectory = toString skills;
    instructions = instructions.concatenated;
    chatPrompt = builtins.readFile ./chat-prompt.md;
    models = {
      inherit (cfg.models) ollama openrouter anthropic openai;
    };
    providers = {inherit (cfg) ollamaUrl openaiKeyFile anthropicKeyFile openrouterKeyFile;};
    mcpServers = lib.mapAttrs (_: server:
      (removeAttrs server ["sourceCommand" "headerFiles"])
      // {
        type = server.type or "streamable-http";
        serverInstructions = server.serverInstructions or true;
      })
    nativeServers;
    localMcpServers = localNames;
    mcpHeaderFiles = lib.mapAttrs (_: server: server.headerFiles or {}) nativeServers;
    programs = {
      librechat = lib.getExe' native.librechat "librechat-server";
      librechatRoot = "${native.librechat}/lib/node_modules/LibreChat";
      node = lib.getExe native.nodejs_24;
      mongodb = lib.getExe' native.mongodb-ce "mongod";
      redis = lib.getExe' native.redis "redis-server";
      meilisearch = lib.getExe native.meilisearch;
      postgres = lib.getExe' postgres "postgres";
      initdb = lib.getExe' postgres "initdb";
      psql = lib.getExe' postgres "psql";
      rustfs = lib.getExe native.rustfs;
      codeApi = lib.getExe' native.librechat-code "librechat-code-service-api";
      codeWorker = lib.getExe' native.librechat-code "librechat-code-worker-server";
      fileServer = lib.getExe' native.librechat-code "librechat-code-file-server";
      toolServer = lib.getExe' native.librechat-code "librechat-code-tool-call-server";
      egressGateway = lib.getExe' native.librechat-code "librechat-code-egress-gateway";
      rag = lib.getExe native.librechat-rag;
      iron = lib.getExe native.iron-proxy;
      ironProto = native.iron-proxy.transformProto;
      gh = lib.getExe native.gh;
      agentsview = toString agentsview;
      qemu = lib.getExe' native.qemu "qemu-system-${hostConfig.arch}";
      socat = lib.getExe native.socat;
    };
    guest = {
      inherit (guest) image kernel initrd init;
      architecture = hostConfig.arch;
      accelerator =
        if pkgs.stdenv.hostPlatform.isDarwin
        then "hvf"
        else "kvm";
    };
  };

  control = native.writeShellScriptBin "librechatctl" ''
    exec ${lib.getExe native.librechat-runtime} "$1" ${manifest} "''${@:2}"
  '';

  service = native.writeShellScript "librechat-service" ''
    exec ${lib.getExe native.librechat-runtime} serve ${manifest}
  '';

  nullableFile = description:
    lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      inherit description;
    };
in {
  imports = [
    ../../ai/mcp.nix
    ../../ai/skills.nix
    ../../ai/provider-credentials.nix
    ../../agentsview/client-options.nix
    ../ollama/home-manager-options.nix
  ];

  options.dotfiles.inference.librechat = {
    stateDirectory = lib.mkOption {
      type = lib.types.str;
      default = "${config.xdg.dataHome}/librechat";
      description = "Private persistent state for the native LibreChat services and conversation workspaces.";
    };

    ollamaUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "http://127.0.0.1:11434";
      description = "Ollama endpoint. Null removes the provider from LibreChat.";
    };

    openaiKeyFile = (nullableFile "Runtime OpenAI key file. Null disables the provider.") // {default = config.dotfiles.ai.openaiApiKeyFile;};
    anthropicKeyFile = (nullableFile "Runtime Anthropic key file. Null disables the provider.") // {default = config.dotfiles.ai.anthropicApiKeyFile;};
    openrouterKeyFile = (nullableFile "Runtime OpenRouter key file. Null disables the provider.") // {default = config.dotfiles.ai.openrouterApiKeyFile;};

    models = {
      anthropic = lib.mkOption {
        type = lib.types.str;
        default = defaultModels.anthropic;
        description = "Initial model for the Anthropic personal agent.";
      };
      openai = lib.mkOption {
        type = lib.types.str;
        default = defaultModels.openai;
        description = "Initial model for the OpenAI personal agent.";
      };
      openrouter = lib.mkOption {
        type = lib.types.str;
        default = modelCatalog.openrouter.sol;
        description = "Initial model for the OpenRouter personal agent.";
      };
      ollama = lib.mkOption {
        type = lib.types.str;
        default = "qwen3:4b";
        description = "Initial local model for the Ollama personal agent.";
      };
    };

    guestMcpServers = lib.mkOption {
      type = lib.types.attrsOf (native.formats.json {}).type;
      default = {};
      description = "Explicit Linux definitions for local shared MCP servers that cannot be re-evaluated from the standard registry.";
    };

    excludeBundles = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Names of entries in dotfiles.ai.bundles to leave out of LibreChat. Their MCP servers, skills and skill runtime dependencies are not added to the conversation guests. The other harnesses keep them.";
    };

    manifest = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
      default = manifest;
      description = "The immutable specification consumed by the LibreChat runtime.";
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = unknownBundles == [];
          message = "dotfiles.inference.librechat.excludeBundles lists bundles that are not in dotfiles.ai.bundles: ${lib.concatStringsSep ", " unknownBundles}";
        }
      ];

      home.packages = [control];
      dotfiles.inference.ollama.models = lib.mkIf (cfg.ollamaUrl == "http://127.0.0.1:11434") [cfg.models.ollama "qwen3-embedding:0.6b"];
    }

    (lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
      systemd.user.services.librechat = {
        Unit = {
          Description = "Personal LibreChat and conversation workspaces";
          After = ["sops-nix.service"];
        };
        Service = {
          ExecStart = toString service;
          Restart = "on-failure";
          RestartSec = 10;
          TimeoutStopSec = "infinity";
        };
        Install.WantedBy = ["default.target"];
      };
    })

    (lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
      launchd.agents.librechat = {
        enable = true;
        config = {
          ProgramArguments = ["${service}"];
          RunAtLoad = true;
          KeepAlive.SuccessfulExit = false;
          ExitTimeOut = 60;
          StandardOutPath = "${config.home.homeDirectory}/Library/Logs/librechat.log";
          StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/librechat.log";
        };
      };
    })
  ];
}
