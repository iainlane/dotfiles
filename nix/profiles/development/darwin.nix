_: {
  flake.homeManagerModules.development-darwin = {pkgs, ...}: {
    home.packages = with pkgs; [
      docker
    ];
  };
}
