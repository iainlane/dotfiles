{pkgs, ...}: let
  workMcp = import ./mcp-servers.nix;
in {
  home.packages = with pkgs; [
    chainctl
    melange
    wolfictl

    openssl

    slack
    vale
  ];

  dotfiles = {
    ai = {
      # The AI tools configured through Home Manager get the work MCP servers.
      mcpServers = workMcp;

      # Work-only skills, alongside the shared set from features/ai.
      skills.weekly-update = ./skills/weekly-update;
    };
    # The organisation already supplies the work MCP servers to Claude Code
    # and Claude Desktop, so exclude those servers from the configuration
    # generated for each of them here.
    claudeCode.excludeMcpServers = builtins.attrNames workMcp;
    claudeDesktop.excludeMcpServers = builtins.attrNames workMcp;

    git.signing = {
      directories."~/dev/chainguard/".ssh.key = "~/.ssh/id_ed25519";
      # Some individual work repositories require gitsign, so install
      # it alongside the default SSH signer.
      gitsign.enable = true;
    };
  };

  # Block the `/share` command so work sessions can't be uploaded to
  # opencode's public share service.
  programs.opencode.settings.share = "disabled";
}
