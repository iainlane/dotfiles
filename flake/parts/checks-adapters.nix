# OS adapter evaluation checks.
#
# The profile-contracts check exercises the resolver against fixtures; this one
# points at the real outputs. Forcing the toplevel drvPath of one
# representative host per adapter (NixOS, nix-darwin, system-manager and
# standalone Home Manager) catches a configuration that no longer evaluates,
# without building anything.
#
# The hosts are picked from `flake.hosts`, one per operating system, so this
# does not need updating when hosts come and go. Evaluating the configurations
# needs the private secrets input, so running this check requires access to it
# (CI passes a deploy key).
{
  config,
  lib,
  ...
}: let
  firstHostWithOs = os:
    lib.head (lib.attrNames (lib.filterAttrs (_: host: host.os == os) config.flake.hosts));

  nixosHost = firstHostWithOs "nixos";
  darwinHost = firstHostWithOs "darwin";
  linuxHost = firstHostWithOs "linux";

  drvPaths = [
    config.flake.nixosConfigurations.${nixosHost}.config.system.build.toplevel.drvPath
    config.flake.darwinConfigurations.${darwinHost}.config.system.build.toplevel.drvPath
    config.flake.systemConfigs.${linuxHost}.config.build.toplevel.drvPath
    config.flake.homeConfigurations."${config.dotfiles.username}@${linuxHost}".activationPackage.drvPath
  ];
in {
  perSystem = {pkgs, ...}: {
    checks.adapter-evals =
      builtins.deepSeq drvPaths
      (pkgs.runCommandLocal "adapter-evals" {} "touch $out");
  };
}
