_: {
  flake.profiles.development.os.darwin.homeManagerModule = {pkgs, ...}: {
    home.packages = with pkgs; [
      docker
    ];
  };

  flake.profiles.development.os.darwin.systemManagerModule = {
    lib,
    ...
  }: {
    homebrew.casks = [
      "orbstack"
    ];
  };
}
