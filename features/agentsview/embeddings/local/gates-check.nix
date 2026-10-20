{
  features,
  featureResolver,
}: {
  pkgs,
  lib,
  ...
}: let
  gateCases = [
    {
      features = [features.agentsview];
      enabled = false;
    }
    {
      features = [features.agentsview features.inference.provides.acceleration.provides.vulkan];
      enabled = true;
    }
    {
      features = [features.agentsview features.inference.provides.acceleration.provides.vulkan.provides.integrated];
      enabled = true;
    }
    {
      features = [features.inference.provides.acceleration.provides.vulkan];
      enabled = false;
    }
    {
      features = [features.agentsview features.inference.provides.acceleration.provides.vulkan];
      excludes = [features.agentsview.provides.embeddings.provides.local];
      enabled = false;
    }
    {
      features = [features.agentsview features.agentsview.provides.embeddings.provides.local];
      enabled = true;
    }
    {
      features = [features.agentsview features.inference.provides.acceleration.provides.metal];
      os = "darwin";
      enabled = true;
    }
    {
      features = [features.agentsview features.inference.provides.acceleration.provides.metal];
      os = "darwin";
      excludes = [features.agentsview.provides.embeddings.provides.local];
      enabled = false;
    }
  ];

  gatePasses = lib.all (test: let
    names = featureResolver.featureNames {
      inherit (test) features;
      excludes = test.excludes or [];
      context = featureResolver.contextForHost {
        os = test.os or "nixos";
        system =
          if (test.os or "nixos") == "darwin"
          then "aarch64-darwin"
          else "x86_64-linux";
      };
    };
  in
    lib.elem features.agentsview.provides.embeddings.provides.local.name names == test.enabled)
  gateCases;
in {
  embedding-feature-selection = assert gatePasses; pkgs.runCommandLocal "embedding-feature-selection" {} "touch $out";
}
