# The nixbuild.net account, as two features. `nixbuild-substituter` gives a
# host the SSH substituter and the keys for it; `nixbuild-builder` also
# registers the account as a remote builder, so builds are offloaded to it.
#
# `lib/nixbuild.nix` holds the constants both features and CI read.
{config, ...}: {
  flake.features = {
    nixbuild-substituter = {
      homeManager = ./home-manager.nix;
      system = ./system.nix;
      nixos = ./nixos.nix;
      darwin = ./darwin.nix;
      systemManager = ./system-manager.nix;
    };

    nixbuild-builder = {
      includes = [config.flake.features.nixbuild-substituter];

      nixos = ./builder-nixos.nix;
      darwin = ./builder-darwin.nix;
      systemManager = ./builder-system-manager.nix;
    };
  };
}
