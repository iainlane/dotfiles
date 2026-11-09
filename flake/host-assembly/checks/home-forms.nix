# Checks which form each host's Home Manager configuration takes.
#
# NixOS and generic Linux hosts build a standalone configuration, so the home
# configuration can be switched without switching the system. nix-darwin hosts
# embed it in the system configuration. A host must never have both forms:
# deploying it would then activate two different home generations in turn.
{
  hosts,
  lib,
  hostResults,
  ...
}: let
  standaloneByOs = {
    nixos = true;
    generic-linux = true;
    darwin = false;
  };
in
  {
    pkgs,
    system,
    ...
  }: let
    nativeHosts = lib.filterAttrs (_: hostConfig: hostConfig.system == system) hosts;

    forms = result: {
      standalone = result.home ? standalone;
      embedded = result.configuration.options ? home-manager;
    };

    actual = lib.mapAttrs (hostname: _: forms hostResults.${hostname}) nativeHosts;
    expected =
      lib.mapAttrs (_: hostConfig: {
        standalone = standaloneByOs.${hostConfig.os};
        embedded = !standaloneByOs.${hostConfig.os};
      })
      nativeHosts;
  in {
    home-forms = lib.lazyDerivation {
      derivation = assert lib.assertMsg (actual == expected)
      "Home Manager configuration forms are ${builtins.toJSON actual}, expected ${builtins.toJSON expected}.";
        pkgs.runCommandLocal "home-forms" {} "touch $out";
      passthru.requiredSystemFeatures = [];
    };
  }
