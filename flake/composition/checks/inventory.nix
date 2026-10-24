{
  lib,
  featureResolver,
}: let
  evaluate = import ../inventory.nix {inherit lib featureResolver;};
  feature = {
    name = "declaration";
    includes = [];
    inventory = {
      hostConfig,
      lib,
      ...
    }: {label = lib.mkDefault hostConfig.name;};
  };
  host = name: {
    inherit name;
    os = "generic-linux";
    system = "x86_64-linux";
    features = [feature];
    excludes = [];
    inventoryModule = {};
    systemConfig = throw "Inventory evaluated runtime configuration.";
    homeConfig = throw "Inventory evaluated Home Manager.";
  };
  actual = evaluate {
    hosts = {
      first = host "first";
      second = (host "second") // {inventoryModule.label = "override";};
    };
    schema.options.label = lib.mkOption {type = lib.types.str;};
  };
in
  {pkgs, ...}: {
    feature-inventory = assert actual
    == {
      first.label = "first";
      second.label = "override";
    };
      pkgs.runCommandLocal "feature-inventory" {} ''touch "$out"'';
  }
