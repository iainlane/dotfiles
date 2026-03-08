{
  flake.profiles.development.os.darwin.homeManagerModule = {pkgs, ...}: {
    home.packages = with pkgs; [
      docker
    ];
  };

  flake.profiles.development.os.darwin.systemManagerModule = {
    homebrew.casks = [
      "orbstack"
    ];
  };
}
