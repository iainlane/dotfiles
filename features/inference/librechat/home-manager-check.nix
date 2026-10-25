{
  features,
  featureResolver,
  modelCatalog,
}: {
  inputs,
  lib,
  pkgs,
  system,
  ...
}: let
  registry = import ../../ai/mcp-server-definitions.nix {inherit inputs pkgs;};

  hostConfig = {
    name = "librechat-fixture";
    arch = pkgs.stdenv.hostPlatform.parsed.cpu.name;
    os =
      if pkgs.stdenv.hostPlatform.isDarwin
      then "darwin"
      else "generic-linux";
    inherit system;
    homeDirectory = "/home/fixture";
    features = [features.inference.librechat];
    excludes = [];
  };

  home = inputs.home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    extraSpecialArgs = {
      inherit inputs hostConfig modelCatalog;
      defaultModels = modelCatalog.defaults;
      pkgs-unstable = pkgs;
      mcp = import ../../ai/mcp-servers.nix {
        inherit inputs lib pkgs;
        inherit (registry) servers serverPackages;
      };
    };
    modules =
      featureResolver.resolveFeatures {
        class = "homeManager";
        inherit hostConfig;
      }
      ++ [
        inputs.sops-nix.homeManagerModules.sops
        {
          home = {
            username = "fixture";
            inherit (hostConfig) homeDirectory;
            stateVersion = "26.05";
          };
        }
      ];
  };

  actual = {
    manifest = builtins.isString home.config.dotfiles.inference.librechat.manifest.drvPath;
    archive = home.config.dotfiles.agentsview.dataDir;
    models = home.config.dotfiles.inference.ollama.models;
  };

  expected = {
    manifest = true;
    archive = "/home/fixture/.agentsview";
    models = map (name: {
      inherit name;
      aliases = [];
      parameters = {};
    }) ["qwen3:4b" "qwen3-embedding:0.6b"];
  };
in {
  librechat-home-manager = assert lib.assertMsg (actual == expected)
  "LibreChat must evaluate without selecting the AgentsView or Ollama service features.";
    pkgs.runCommandLocal "librechat-home-manager" {} "touch $out";
}
