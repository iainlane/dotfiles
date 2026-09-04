{
  baseConfiguration,
  patch,
  pkgs,
  promptEnvironment,
  promptSource,
}: let
  variantSource = pkgs.applyPatches {
    name = "prompt-conformance-variant-source";
    src = promptSource;
    patches = [patch];
  };
  instructions =
    (import (variantSource + "/agent-instructions.nix") {
      inherit (pkgs) lib;
      source = variantSource;
    }).harnesses.claudeCode;
  # The decoded values are edited as plain data. Their original store
  # dependencies remain attached to the configuration written below.
  baseText = builtins.readFile baseConfiguration;
  baseContext = builtins.getContext baseText;
  base = builtins.fromJSON (builtins.unsafeDiscardStringContext baseText);
  managedSettings = builtins.fromJSON (
    builtins.unsafeDiscardStringContext (
      builtins.readFile (builtins.appendContext base.claude.settings baseContext)
    )
  );
  environment = import promptEnvironment {
    inherit instructions managedSettings pkgs;
    inherit (pkgs) lib;
  };
  baseRunMetadata = builtins.fromJSON (
    builtins.unsafeDiscardStringContext (
      builtins.readFile (builtins.appendContext base.runMetadata baseContext)
    )
  );
  runMetadata = pkgs.writeText "prompt-conformance-variant-run.json" (
    builtins.toJSON (
      baseRunMetadata
      // {
        prompt =
          pkgs.lib.mapAttrs (_: content: builtins.hashString "sha256" content)
          instructions.files;
        outputStyles = pkgs.lib.mapAttrs (_: style:
          builtins.hashFile "sha256" style.file)
        instructions.outputStyles;
        defaultOutputStyle = managedSettings.outputStyle;
      }
    )
  );
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
  configuration = pkgs.writeText "prompt-conformance-variant-configuration.json" (
    builtins.appendContext
    (builtins.toJSON configurationValue)
    (builtins.getContext baseText)
  );
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
