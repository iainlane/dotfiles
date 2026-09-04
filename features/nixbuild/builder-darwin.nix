{
  config,
  inputs,
  ...
}: let
  nixbuild = import ../../lib/nixbuild.nix {inherit (inputs.nixpkgs) lib;};
in {
  # Determinate Nix reads builders = @/etc/nix/machines by default.
  environment.etc."nix/machines".text =
    nixbuild.machineLines nixbuild.systems
    config.sops.secrets.nixbuild-private-key.path;
}
