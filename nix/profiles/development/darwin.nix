_: {
  flake.profiles.development.os.darwin.homeManagerModule = {pkgs, ...}: {
    home.packages = with pkgs; [
      docker
    ];
  };
}
