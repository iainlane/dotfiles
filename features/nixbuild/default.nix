# The nixbuild.net connection and remote builder features. `nixbuild` provides
# the SSH aliases and credentials; `nixbuild-builder` also registers the
# account as a remote builder.
#
# `lib/nixbuild.nix` defines the constants both features and CI read.
{config, ...}: {
  dotfiles.features = {
    nixbuild = {
      homeManager = ./home-manager.nix;
      system = ./system.nix;
      nixos = ./nixos.nix;
      darwin = ./darwin.nix;
      systemManager = ./system-manager.nix;
    };

    nixbuild-builder = {
      includes = [config.dotfiles.features.nixbuild];

      nixos = ./builder-nixos.nix;
      darwin = ./builder-darwin.nix;
      systemManager = ./builder-system-manager.nix;
    };
  };
}
