{
  baseConfiguration,
  patch,
  pkgs,
  promptEnvironment,
  promptSource,
}: let
  inherit (pkgs) lib;
  variantSource = pkgs.applyPatches {
    name = "prompt-conformance-variant-source";
    src = promptSource;
    patches = [patch];
  };
  instructions =
    (import (variantSource + "/agent-instructions.nix") {
      inherit lib;
      source = variantSource;
    }).harnesses.claudeCode;
  # `builtins.readFile` returns a string with no context, so the store paths the
  # base configuration names are plain text here and stay plain text in the
  # configuration written below. The run's garbage-collector root over the base
  # configuration is what keeps the programs both configurations name alive.
  base = builtins.fromJSON (builtins.readFile baseConfiguration);
  managedSettings = builtins.fromJSON (builtins.readFile base.claude.settings);
  environment = import promptEnvironment {
    inherit instructions lib managedSettings pkgs;
  };
  baseRunMetadata = builtins.fromJSON (builtins.readFile base.runMetadata);
  runMetadata =
    pkgs.writeText "prompt-conformance-variant-run.json"
    (builtins.toJSON (baseRunMetadata // environment.promptDigests));
  configurationValue =
    base
    // {
      inherit (environment) candidateContext promptContext workspaceOverlay;
      inherit runMetadata;
      claude =
        base.claude
        // {
          settings = environment.managedSettingsFile;
          inherit (managedSettings) outputStyle;
        };
      variant =
        base.variant
        // {
          promptSource = variantSource;
        };
    };
  configuration =
    pkgs.writeText "prompt-conformance-variant-configuration.json"
    (builtins.toJSON configurationValue);
in
  pkgs.linkFarm "prompt-conformance-variant" [
    {
      name = "configuration.json";
      path = configuration;
    }
    {
      name = "prompt-source";
      path = variantSource;
    }
    {
      name = "run-metadata.json";
      path = runMetadata;
    }
  ]
