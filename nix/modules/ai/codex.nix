# Wrap Codex so it always uses the shared MCP servers.
{
  pkgs,
  inputs,
  lib,
  system,
  ...
}: let
  mcp = import ./mcp-servers.nix {inherit pkgs inputs lib;};

  # Codex requires inline TOML config via `-c`. We generate the TOML once with
  # `toml-inline` format (produces a single-line string suitable for CLI), then
  # wrap the binary to inject it. This ensures Codex always has the MCP servers
  # without users needing to pass flags manually.
  codexMcpConfig = mcp.mkConfigFile "codex" "toml-inline" ".mcp.toml";

  # Codex needs custom wrapping for MCP config, so we manually add both the
  # MCP config flags and the shared tools to PATH
  codexWrapped = pkgs.symlinkJoin {
    name = "codex";
    paths = [inputs.llm-agents.packages.${system}.codex];
    nativeBuildInputs = [pkgs.makeWrapper];
    postBuild = ''
      wrapProgram $out/bin/codex \
        --add-flags "-c '$(cat ${codexMcpConfig})'" \
        --prefix PATH : ${lib.makeBinPath mcp.packages}
    '';
  };
in {
  programs.codex = {
    enable = true;
    package = codexWrapped;
  };
}
