{lib}: let
  classesFor = kind: descriptions:
    lib.mapAttrs (name: description: {
      inherit description kind;
      destination = _: name;
    })
    descriptions;
in
  classesFor "configuration" {
    nixos = "NixOS module.";
    darwin = "nix-darwin module.";
    systemManager = "system-manager module.";
    homeManager = "Home Manager module.";
  }
  // classesFor "output" {
    packages = "Packages exported by the feature.";
    apps = "Runnable applications exported by the feature.";
    checks = "Checks exported by the feature.";
    devShells = "Development shells exported by the feature.";
    legacyPackages = "Nested outputs exported by the feature.";
  }
  // {
    system = {
      description = "Module for the host's primary configuration class.";
      kind = "alias";
      destination = context: context.systemClass or null;
    };
  }
