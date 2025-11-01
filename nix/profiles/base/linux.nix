{pkgs, ...}: {
  home.packages = with pkgs; [
    # simplified alternative to strace
    lurk
  ];

  targets.genericLinux.enable = true;
}
