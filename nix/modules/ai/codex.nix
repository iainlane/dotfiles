# Configure Codex with the shared MCP servers. Use a system-level managed
# configuration file, so that user changes can be written to the file under the
# home dir.
_: let
  # This matches the `home-manager` module for Codex.
  managedConfigModule = {
    pkgs,
    inputs,
    lib,
    ...
  }: let
    mcp = import ./mcp-servers.nix {inherit pkgs inputs lib;};

    managedConfig = {
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
        mcp.servers;
    };

    managedConfigFile = (pkgs.formats.toml {}).generate "codex-managed-config.toml" managedConfig;
  in {
    environment.etc."codex/managed_config.toml".source = managedConfigFile;
  };

  homeManagerModule = {
    pkgs,
    inputs,
    lib,
    system,
    ...
  }: let
    mcp = import ./mcp-servers.nix {inherit pkgs inputs lib;};

    # Wrap Codex to add shared tools to PATH.
    wrappedCodex = mcp.wrapWithTools {
      package = inputs.llm-agents.packages.${system}.codex;
      binName = "codex";
    };
  in {
    programs.codex = {
      enable = true;
      package = wrappedCodex;
    };
  };
in {
  flake.modules.ai = {
    homeManagerModules = [homeManagerModule];
    systemManagerModules = [managedConfigModule];
    nixosModules = [managedConfigModule];
  };
}
