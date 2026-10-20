{
  features,
  featureResolver,
}: {
  pkgs,
  lib,
  ...
}: let
  vulkan = features.inference.provides.acceleration.provides.vulkan;

  integratedGpuCases = [
    {
      class = "nixos";
      os = "nixos";
      feature = vulkan;
      expected = {};
    }
    {
      class = "nixos";
      os = "nixos";
      feature = vulkan.provides.integrated;
      expected.OLLAMA_IGPU_ENABLE = "1";
    }
    {
      class = "homeManager";
      os = "generic-linux";
      feature = vulkan;
      expected = {};
    }
    {
      class = "homeManager";
      os = "generic-linux";
      feature = vulkan.provides.integrated;
      expected.OLLAMA_IGPU_ENABLE = "1";
    }
    {
      class = "homeManager";
      os = "nixos";
      feature = vulkan.provides.integrated;
      expected = {};
    }
  ];

  integratedGpuResults =
    map (test: let
      evaluated = lib.evalModules {
        modules =
          [
            {
              options = {
                hardware.graphics.enable = lib.mkEnableOption "graphics support";
                services.ollama.environmentVariables = lib.mkOption {
                  type = lib.types.attrsOf lib.types.str;
                  default = {};
                };
              };
            }
          ]
          ++ featureResolver.resolveFeatures {
            inherit (test) class;
            hostConfig = {
              name = "fixture";
              inherit (test) os;
              system = "x86_64-linux";
              features = [test.feature];
              excludes = [];
            };
          };
      };
    in {
      inherit (test) class os expected;
      actual = evaluated.config.services.ollama.environmentVariables;
    })
    integratedGpuCases;
in {
  ollama-integrated-gpu = assert lib.assertMsg
  (lib.all (result: result.actual == result.expected) integratedGpuResults)
  "Ollama integrated GPU feature checks failed: ${builtins.toJSON integratedGpuResults}";
    pkgs.runCommandLocal "ollama-integrated-gpu" {} "touch $out";
}
