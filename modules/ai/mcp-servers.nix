{
  pkgs,
  pkgs-unstable,
  inputs,
  lib,
}:
# Define the shared MCP server set once and let each tool consume it.
let
  mcpRemote = import ./mcp-remote.nix {inherit lib pkgs;};

  # The servers every tool should talk to.
  programs = {
    codex = {
      enable = true;
      package = import ./codex/package.nix {
        inherit inputs;
        system = pkgs.stdenv.hostPlatform.system;
      };
    };

    context7.enable = true;

    fetch.enable = false;

    git.enable = true;

    github = {
      enable = false;
      package = pkgs.github-mcp-server;
      passwordCommand = {
        GITHUB_PERSONAL_ACCESS_TOKEN = ["gh" "auth" "token"];
      };
    };

    nixos = {
      enable = true;
      # mcp-nixos checks for updates on startup, which is slow and noisy; turn
      # it off so the server comes up quickly.
      env.FASTMCP_CHECK_FOR_UPDATES = "off";
    };

    playwright = {
      enable = true;
      env.PLAYWRIGHT_HTML_OPEN = "false";
    };
  };

  # Evaluate the mcp-servers-nix module to get a computed attrset of MCP server
  # definitions. This gives us the shared server shape; each harness can then
  # either consume it directly or mirror it through `programs.mcp`.
  mcpServersNix = inputs.mcp-servers-nix.lib.evalModule pkgs-unstable {
    inherit programs;
  };

  # Pull out the computed server definitions for reuse.
  inherit (mcpServersNix.config.settings) servers;

  exaServer = {apiKeyFile}:
    mcpRemote.mkServer {
      name = "exa";
      url = "https://mcp.exa.ai/mcp";
      envFiles.EXA_API_KEY = apiKeyFile;
      headerEnv."x-api-key" = "EXA_API_KEY";
    };

  hostSecretServerDefinitions = {
    exa = {
      file = "user-exa.yaml";
      key = "exa_api_key";
      server = apiKeyFile: exaServer {inherit apiKeyFile;};
    };
  };

  hostSecretServers = {
    hostname,
    secretPath,
    declareSopsSecrets ? true,
  }: let
    availableServers =
      lib.filterAttrs
      (_name: definition: builtins.pathExists (inputs.secrets + "/${hostname}/${definition.file}"))
      hostSecretServerDefinitions;
  in {
    servers = lib.mapAttrs (_name: definition: definition.server (secretPath definition.key)) availableServers;

    sopsSecrets =
      lib.optionalAttrs declareSopsSecrets
      (lib.mapAttrs' (
          _name: definition:
            lib.nameValuePair definition.key {
              sopsFile = inputs.secrets + "/${hostname}/${definition.file}";
            }
        )
        availableServers);
  };

  jsonFormat = pkgs.formats.json {};

  # Declaration for the MCP server set offered to the AI harnesses. Servers are
  # held in the common shape (`url` for remote, `command`/`args` for local); a
  # base module seeds the set and profiles contribute more, with the module
  # system merging the definitions. Each harness applies its own transform to
  # output in the format it needs.
  mcpServersOption = lib.mkOption {
    type = with lib.types; attrsOf (attrsOf jsonFormat.type);
    default = {};
    description = "MCP servers offered to the AI harnesses.";
  };

  # Remove named servers from a set. A harness uses this to drop servers a
  # profile has excluded for it.
  excludeServers = names: serverSet: lib.removeAttrs serverSet names;

  # These language servers, formatters, and linters are made privately
  # available to the AI tools that can use project diagnostics.
  packages = with pkgs; [
    alejandra
    bash-language-server
    clang-tools # provides clangd
    deadnix
    deno
    ffmpeg
    gopls
    lua-language-server
    marksman
    nil
    pkgs."typescript-language-server"
    pyright
    rust-analyzer
    shellcheck
    shfmt
    statix
    taplo
    yaml-language-server
    yt-dlp
  ];
in {
  inherit packages mcpServersOption excludeServers mcpRemote hostSecretServers servers;

  # Helper function to wrap an AI tool with the shared tools in PATH
  wrapWithTools = {
    package,
    binName,
    extraWrapperArgs ? [],
  }: let
    wrapped =
      pkgs.runCommand "${binName}-with-tools" {
        nativeBuildInputs = [pkgs.makeWrapper];
      } ''
        makeWrapper ${package}/bin/${binName} $out/bin/${binName} \
          --prefix PATH : ${lib.makeBinPath packages}${lib.optionalString (extraWrapperArgs != []) " \\\n          ${lib.escapeShellArgs extraWrapperArgs}"}
      '';
  in
    wrapped
    // {
      inherit (package) meta name pname version;
      passthru =
        (package.passthru or {})
        // {
          unwrapped = package;
        };
    };
}
