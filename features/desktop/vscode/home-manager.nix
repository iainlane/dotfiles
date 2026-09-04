{pkgs, ...}: {
  programs.vscode = {
    enable = true;

    profiles.default = {
      enableMcpIntegration = true;
      extensions = with pkgs.vscode-extensions; [
        catppuccin.catppuccin-vsc
      ];
    };
  };
}
