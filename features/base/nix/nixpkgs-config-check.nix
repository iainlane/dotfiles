{
  hostConfig,
  homeConfig,
}: {
  inputs,
  lib,
  pkgs,
  ...
}: let
  settings = import ../../../lib/nixpkgs-config.nix;

  # Nixpkgs checks a setting's type when the option is read, so read every
  # option.
  accepts = nixpkgs:
    lib.all (value: builtins.seq value true) (lib.attrValues
      (import nixpkgs {
        inherit (pkgs.stdenv.hostPlatform) system;
        config = settings;
        overlays = [];
      }).config);

  written = homeConfig.xdg.configFile."nixpkgs/config.nix".text == lib.generators.toPretty {} settings;
  accepted = accepts inputs.nixpkgs && accepts inputs.nixpkgs-stable;
in {
  "host-evaluation-nixpkgs-config-${hostConfig.name}" = lib.lazyDerivation {
    derivation = assert lib.assertMsg written "~/.config/nixpkgs/config.nix must contain the settings from lib/nixpkgs-config.nix";
    assert lib.assertMsg accepted "Both nixpkgs channels must accept the settings in lib/nixpkgs-config.nix";
      pkgs.runCommandLocal "nixpkgs-config" {} "touch $out";
    passthru.requiredSystemFeatures = [];
  };
}
