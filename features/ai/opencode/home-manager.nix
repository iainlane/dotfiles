{
  config,
  inputs,
  instructions,
  lib,
  mcp,
  pkgs,
  system,
  ...
}: let
  cfg = config.dotfiles.opencode;

  jsonFormat = pkgs.formats.json {};

  mkMcpServer = server:
    {disabled = server.disabled or false;}
    // (
      if server ? url
      then
        {
          type = "remote";
          inherit (server) url;
        }
        // lib.optionalAttrs (server ? headers) {inherit (server) headers;}
      else
        {
          type = "local";
          command = [server.command] ++ (server.args or []);
        }
        // lib.optionalAttrs (server ? env) {environment = server.env;}
    );

  opencode2 = inputs.llm-agents.packages.${system}.opencode2;
  opencode = pkgs.symlinkJoin {
    pname = "opencode";
    inherit (opencode2) version;
    meta = opencode2.meta // {mainProgram = "opencode";};
    passthru = opencode2.passthru or {};
    paths = [opencode2];
    postBuild = ''
      mv "$out/bin/opencode2" "$out/bin/opencode"
    '';
  };

  wrappedOpencode = mcp.wrapWithTools {
    package = opencode;
    binName = "opencode";
    extraWrapperArgs =
      [
        "--set"
        "OPENCODE_DISABLE_CLAUDE_CODE_SKILLS"
        "1"
      ]
      ++ lib.optionals (cfg.cliConfig != {}) [
        "--set"
        "OPENCODE_CLI_CONFIG_CONTENT"
        (builtins.toJSON cfg.cliConfig)
      ];
  };
in {
  options.dotfiles.opencode.cliConfig = lib.mkOption {
    inherit (jsonFormat) type;
    default = {};
    description = ''
      Settings merged over `cli.json` through `OPENCODE_CLI_CONFIG_CONTENT`.
      OpenCode 2 does not persist these overrides. Lists replace the
      corresponding lists in `cli.json`, including `plugins`.
    '';
  };

  config = {
    programs.opencode = {
      enable = true;
      package = wrappedOpencode;
      context = instructions.concatenated;
      enableMcpIntegration = false;

      settings = {
        autoupdate = false;
        mcp.servers = lib.mapAttrs (_name: mkMcpServer) config.dotfiles.ai.mcpServers;
      };
    };

    # OpenCode rewrites cli.json. It imports tui.json only if cli.json is absent.
    xdg.configFile."opencode/tui.json".source =
      jsonFormat.generate "tui.json" {theme = "system";};
  };
}
