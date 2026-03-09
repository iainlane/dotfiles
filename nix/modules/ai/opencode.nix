{
  pkgs,
  inputs,
  lib,
  options,
  system,
  ...
}: let
  mcp = import ./mcp-servers.nix {inherit pkgs inputs lib;};

  # Wrap OpenCode to add shared tools to PATH
  wrappedOpencode = mcp.wrapWithTools {
    package = inputs.llm-agents.packages.${system}.opencode;
    binName = "opencode";
  };

  hasOpencodeModule = options ? programs && options.programs ? opencode;
in {
  config =
    if hasOpencodeModule
    then {
      programs.opencode = {
        enable = true;
        package = wrappedOpencode;
        enableMcpIntegration = true;
      };
    }
    else {
      home.packages = [wrappedOpencode];
    };
}
