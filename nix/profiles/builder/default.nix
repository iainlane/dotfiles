{
  imports = [
    ./linux.nix
    ./darwin.nix
  ];

  flake.profiles.builder.homeManagerModule = {};
}
