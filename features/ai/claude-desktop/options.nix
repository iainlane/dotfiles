{lib, ...}: {
  options.dotfiles.claudeDesktop.excludeMcpServers = lib.mkOption {
    type = with lib.types; listOf str;
    default = [];
    description = ''
      Names of shared MCP servers to drop from Claude Desktop. The work
      profile uses this to exclude the enterprise connectors, which Claude
      Desktop receives from the organisation directly.
    '';
  };
}
