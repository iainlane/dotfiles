# NixOS builder profile: configures nixbuild.net as a remote builder and enables
# binfmt emulation for aarch64-linux on x86_64 hosts.
{inputs, ...}: let
  nixbuild = import ./nixbuild-common.nix {inherit (inputs.nixpkgs) lib;};
in {
  flake.profiles.builder.os.nixos.nixosModule = {
    config,
    lib,
    hostConfig,
    ...
  }: {
    imports = [
      nixbuild.module
    ];

    nix.buildMachines =
      map (system: {
        hostName = nixbuild.builderAlias;
        inherit system;
        sshKey = config.sops.secrets.nixbuild-private-key.path;
        inherit (nixbuild) maxJobs speedFactor supportedFeatures;
      })
      nixbuild.systems;

    boot.binfmt.emulatedSystems = lib.mkIf (hostConfig.arch == "x86_64") ["aarch64-linux"];
  };
}
