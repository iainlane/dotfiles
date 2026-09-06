{
  config,
  inputs,
  ...
}: let
  nixbuild = import ../../lib/nixbuild.nix {inherit (inputs.nixpkgs) lib;};
in {
  # The Determinate nix-darwin module writes `/etc/nix/machines` from this
  # option, as the NixOS module does from `nix.buildMachines`. `protocol` is
  # null because the account is reached through the `nixbuild-builder` SSH
  # alias, which `lib/nixbuild.nix` configures; a protocol here would put an
  # `ssh://` prefix in front of the alias.
  determinateNix = {
    distributedBuilds = true;

    buildMachines =
      map (system: {
        hostName = nixbuild.builderAlias;
        protocol = null;
        inherit system;
        sshKey = config.sops.secrets.nixbuild-private-key.path;
        inherit (nixbuild) maxJobs speedFactor supportedFeatures;
      })
      nixbuild.systems;
  };
}
