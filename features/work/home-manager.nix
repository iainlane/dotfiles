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
      # Home Manager tools get the enterprise connectors here.
      mcpServers = workMcp;

      # Work-only skills, alongside the shared set from features/ai.
      skills.weekly-update = ./skills/weekly-update;
    };
    # Claude Code and Claude Desktop receive these from the
    # organisation, so don't dupe.
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
