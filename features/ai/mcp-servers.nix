{
  pkgs,
  inputs,
  lib,
  # The server definitions from `mcp-server-definitions.nix`, evaluated once
  # per system by `features/ai/default.nix` and passed in for both channels.
  # Each harness either consumes them directly or mirrors them through
  # `programs.mcp`.
  servers,
  serverPackages,
}:
# The per-channel half of the shared MCP server set: the tools built from this
# channel's package set, and the helpers each harness uses to reshape the
# servers.
let
  mcpRemote = import ./mcp-remote.nix {inherit lib pkgs;};
  remoteServers = import ./mcp-remote-servers.nix;

  exaServer = {apiKeyFile}:
    mcpRemote.mkServer {
      name = "exa";
      inherit (remoteServers.exa) url;
      envFiles.EXA_API_KEY = apiKeyFile;
      headerEnv.${remoteServers.exa.token.header} = "EXA_API_KEY";
    };

  hostSecretServerDefinitions = {
    exa = {
      file = "user-exa.yaml";
      key = "exa_api_key";
      server = apiKeyFile: exaServer {inherit apiKeyFile;};
    };
  };

  hostSecretServers = {
    host,
    secretPath,
    declareSopsSecrets ? true,
  }: let
    availableServers =
      lib.filterAttrs
      (_name: definition: builtins.pathExists (inputs.secrets + "/${host}/${definition.file}"))
      hostSecretServerDefinitions;
  in {
    servers = lib.mapAttrs (_name: definition: definition.server (secretPath definition.key)) availableServers;

    sopsSecrets =
      lib.optionalAttrs declareSopsSecrets
      (lib.mapAttrs' (
          _name: definition:
            lib.nameValuePair definition.key {
              sopsFile = inputs.secrets + "/${host}/${definition.file}";
            }
        )
        availableServers);
  };

  jsonFormat = pkgs.formats.json {};

  # Declaration for the MCP server set offered to the AI harnesses. Servers
  # use one common shape (`url` for remote, `command`/`args` for local); a
  # base module seeds the set and features add to it, with the module system
  # merging the definitions. Each harness applies its own transform to output
  # in the format it needs.
  mcpServersOption = lib.mkOption {
    type = with lib.types; attrsOf (attrsOf jsonFormat.type);
    default = {};
    description = "MCP servers offered to the AI harnesses.";
  };

  # Remove named servers from a set. A harness uses this to drop servers a
  # feature has excluded for it.
  excludeServers = names: serverSet: lib.removeAttrs serverSet names;

  # These language servers, formatters and linters go on the PATH of the AI
  # tools that can use project diagnostics, and nowhere else.
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
    typescript-language-server
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
  inherit mcpServersOption excludeServers mcpRemote hostSecretServers serverPackages servers;

  # Wrap an AI tool so the shared tools are on its PATH. The result contains
  # everything the package installs, keeps its `pname`, `version`, `meta` and
  # `passthru`, and puts the unwrapped package under `passthru.unwrapped`.
  wrapWithTools = {
    package,
    binName,
    extraWrapperArgs ? [],
  }:
    pkgs.symlinkJoin {
      inherit (package) pname version meta;
      paths = [package];
      nativeBuildInputs = [pkgs.makeWrapper];
      postBuild = ''
        wrapProgram "$out/bin/${binName}" \
          --prefix PATH : ${lib.makeBinPath packages} \
          ${lib.escapeShellArgs extraWrapperArgs}
      '';
      passthru =
        (package.passthru or {})
        // {
          unwrapped = package;
        };
    };
}
