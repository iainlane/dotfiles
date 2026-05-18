{
  inputs,
  lib,
  config,
  ...
}: let
  helpers = import ../../lib/helpers.nix {inherit inputs;};

  username = "laney";

  # Common overlays used across all systems.
  # Local overlays are discovered automatically from `overlays/*.nix` (sorted)
  # and instantiated with the shared `{ inputs }` contract.
  overlays = helpers.importNixFiles ../../overlays {inherit inputs;};

  # Common nixpkgs configuration used across all systems
  nixpkgsConfig = {
    allowUnfree = true;
  };
in {
  config = {
    _module.args.context = {
      inherit
        lib
        username
        overlays
        nixpkgsConfig
        ;
    };

    # Make packages available under:
    #
    #   .#hostPrograms.<hostname>.nh.package
    #
    # and then external consumers like `./just` can run the same versions using
    # `nix run`.
    flake.hostPrograms =
      lib.mapAttrs (
        hostname: _:
          config.flake.homeConfigurations."${username}@${hostname}".config.programs
      )
      config.flake.hosts;

    perSystem = {system, ...}: let
      mkPkgs = nixpkgs:
        import nixpkgs {
          inherit system overlays;
          config = nixpkgsConfig;
        };
      pkgs = mkPkgs inputs.nixpkgs;
      pkgs-stable = mkPkgs inputs.nixpkgs-stable;
    in {
      _module.args = {inherit pkgs pkgs-stable;};
    };
  };
}
