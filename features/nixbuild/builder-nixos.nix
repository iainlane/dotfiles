{
  config,
  inputs,
  lib,
  hostConfig,
  ...
}: let
  nixbuild = import ../../lib/nixbuild.nix {inherit (inputs.nixpkgs) lib;};
in {
  nix.distributedBuilds = true;
  nix.buildMachines =
    map (system: {
      hostName = nixbuild.builderAlias;
      inherit system;
      sshKey = config.sops.secrets.nixbuild-private-key.path;
      inherit (nixbuild) maxJobs speedFactor supportedFeatures;
    })
    nixbuild.systems;

  boot.binfmt.emulatedSystems = lib.mkIf (hostConfig.arch == "x86_64") ["aarch64-linux"];
}
