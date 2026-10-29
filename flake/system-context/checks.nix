{
  inputs,
  lib,
}: {pkgs, ...}: let
  home = import ../../lib/home.nix {
    inherit inputs lib;
    featureResolver = {};
  };
  systemArgs = import ../../lib/system.nix {inherit inputs;};
  systems = ["x86_64-linux" "aarch64-darwin"];
  fixture = inputs.flake-parts.lib.evalFlakeModule {inputs = {};} ({
    flakeContexts,
    withSystem,
    ...
  }: {
    imports = [./arguments.nix];
    inherit systems;
    perSystem = {system, ...}: {
      dotfiles.shared = {
        resource = {
          inherit system;
          value = 42;
        };
        unused = throw "An unused context resource was evaluated.";
      };
    };
    flake.observed = lib.genAttrs systems (system:
      withSystem system ({flakeContext, ...}: let
        hostConfig = {
          inherit system;
          channel = "unstable";
        };
        common = {
          inherit hostConfig flakeContexts;
          hostInventory = {};
          modelCatalog = {};
          mcpByChannel.unstable = {};
        };
        homeArgs = home.mkHomeSpecialArgs (common
          // {
            pkgs = {};
            pkgs-stable = {};
          });
        osArgs = systemArgs.mkSystemSpecialArgs (common
          // {
            username = "fixture";
            channel.unstable = {};
          });
      in {
        names = lib.attrNames flakeContext;
        native = flakeContext.resource;
        home = homeArgs.flakeContext.resource;
        os = osArgs.flakeContext.resource;
        cross = flakeContexts.${lib.findFirst (other: other != system) null systems}.resource;
      }));
  });
  actual = fixture.config.flake.observed;
  linux = {
    system = "x86_64-linux";
    value = 42;
  };
  darwin = {
    system = "aarch64-darwin";
    value = 42;
  };
  expected = {
    x86_64-linux = {
      names = ["resource" "unused"];
      native = linux;
      home = linux;
      os = linux;
      cross = darwin;
    };
    aarch64-darwin = {
      names = ["resource" "unused"];
      native = darwin;
      home = darwin;
      os = darwin;
      cross = linux;
    };
  };
in {
  system-context =
    pkgs.runCommandLocal "system-context" {
      passed = actual == expected;
    } ''
      test "$passed" = 1
      touch "$out"
    '';
}
