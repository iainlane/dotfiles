# Configure Codex with the shared MCP servers. Use a system-level managed
# configuration file, so that user changes can be written to the file under the
# home dir.
_: let
  # This matches the `home-manager` module for Codex.
  managedConfigModule = {
    pkgs,
    pkgs-unstable,
    inputs,
    lib,
    ...
  }: let
    mcp = import ./mcp-servers.nix {inherit pkgs pkgs-unstable inputs lib;};

    managedConfig = {
      # Updates come from Nix, not codex's self-check.
      check_for_update_on_startup = false;
      features = {
        apps = true;
        memories = true;
        smart_approvals = true;
        undo = true;
      };
      mcp_servers =
        lib.mapAttrs (
          _name: server: let
            url = server.url or null;
            headers = server.headers or {};
            httpHeaders = server.http_headers or null;
            hasRemoteHeaders =
              url
              != null
              && headers != {}
              && httpHeaders == null;
          in
            (lib.removeAttrs server [
              "disabled"
              "headers"
            ])
            // (lib.optionalAttrs hasRemoteHeaders {
              http_headers = headers;
            })
            // {
              enabled = !(server.disabled or false);
            }
        )
        # Codex shouldn't run itself as an MCP server.
        (lib.removeAttrs mcp.servers ["codex"]);
      model = "gpt-5.5";
      model_reasoning_effort = "high";
      personality = "pragmatic";
      service_tier = "fast";
      suppress_unstable_features_warning = true;
      web_search = "live";
      zsh_path = "${pkgs.zsh}/bin/zsh";
    };

    managedConfigFile = (pkgs.formats.toml {}).generate "codex-managed-config.toml" managedConfig;
  in {
    environment.etc."codex/managed_config.toml".source = managedConfigFile;
  };

  homeManagerModule = {
    pkgs,
    pkgs-unstable,
    inputs,
    lib,
    system,
    ...
  }: let
    mcp = import ./mcp-servers.nix {inherit pkgs pkgs-unstable inputs lib;};
    instructions = import ./agent-instructions.nix {inherit lib;};
    skills = import ./skills.nix {inherit lib;};

    # Wrap Codex to add shared tools to PATH.
    wrappedCodex = mcp.wrapWithTools {
      package = inputs.llm-agents.packages.${system}.codex;
      binName = "codex";
    };
  in {
    programs.codex = {
      enable = true;
      package = wrappedCodex;

      context = instructions.concatenated;

      # Shared skills from ./skills/.
      inherit skills;
    };
  };
in {
  flake.modules.ai = {
    homeManagerModules = [homeManagerModule];
    systemManagerModules = [managedConfigModule];
    nixosModules = [managedConfigModule];
  };
}
