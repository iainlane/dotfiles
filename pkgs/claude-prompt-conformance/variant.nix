# Rebuilds the prompt from a patched copy of the instruction sources. An
# improvement run builds this expression for each proposal it races, and
# replaces the prompt inputs of the run with the directory below.
{
  managedSettings,
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
  environment = import promptEnvironment {
    inherit instructions lib pkgs;
    managedSettings = builtins.fromJSON (builtins.readFile managedSettings);
  };
in
  pkgs.linkFarm "prompt-conformance-variant" [
    {
      name = "candidate-context";
      path = environment.candidateContext;
    }
    {
      name = "managed-settings.json";
      path = environment.managedSettingsFile;
    }
    {
      name = "prompt-context.json";
      path = environment.promptContext;
    }
    {
      name = "prompt-source";
      path = variantSource;
    }
    {
      name = "workspace-overlay";
      path = environment.workspaceOverlay;
    }
  ]
