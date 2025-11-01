_: {
  flake.homeManagerModules.base-linux = {pkgs, ...}: {
    home.packages = with pkgs; [
      lurk
    ];

    targets.genericLinux.enable = true;
  };
}
