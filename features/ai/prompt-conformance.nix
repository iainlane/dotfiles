# Gives the prompt-conformance suite the prompt this flake actually deploys.
#
# The suite package builds the program, its fixtures and the machinery of a
# run, and takes the configuration it measures on the command line. This module
# assembles that configuration from the instruction set, the managed settings
# and the model table of this feature, wraps the program with it, and exposes
# the result as `nix run .#claude-prompt-conformance`.
{
  inputs,
  lib,
  ...
}: {
  perSystem = {pkgs, ...}: let
    defaultModels = import ./models.nix;
    instructions =
      (import ./agent-instructions.nix {inherit lib;}).harnesses.claudeCode;
    managedSettings =
      (lib.evalModules {
        modules = [./claude-code/managed-settings-common.nix];
        specialArgs = {inherit defaultModels inputs pkgs;};
      }).config.dotfiles.claudeCode.managedSettings;
    # Dropped: the settings that would change the measured prompt, and the
    # settings that need host services the isolated candidate is denied.
    suiteManagedSettings = removeAttrs managedSettings [
      "enabledPlugins"
      "extraKnownMarketplaces"
      "fileSuggestion"
      "statusLine"
      "voiceEnabled"
    ];

    suite = pkgs.claude-prompt-conformance;
    promptEnvironment = import suite.promptEnvironment {
      inherit instructions lib pkgs;
      managedSettings = suiteManagedSettings;
    };
    # What a prompt variant patches: the instruction and style files, and the
    # two expressions that assemble them.
    promptSource = lib.fileset.toSource {
      root = ./.;
      fileset = lib.fileset.unions [
        ./agent-instructions.nix
        ./instructions
        ./output-style
        ./output-styles.nix
      ];
    };

    # Configure the judge independently so changing the candidate or improver
    # defaults does not also change the model that assesses their evidence.
    judgeModel = "gpt-5.6-terra";
    configurationFlags = [
      "--managed-settings"
      "${promptEnvironment.managedSettingsFile}"
      "--candidate-context"
      "${promptEnvironment.candidateContext}"
      "--workspace-overlay"
      "${promptEnvironment.workspaceOverlay}"
      "--prompt-context"
      "${promptEnvironment.promptContext}"
      "--prompt-source"
      "${promptSource}"
      "--candidate-model"
      suiteManagedSettings.model
      "--output-style"
      suiteManagedSettings.outputStyle
      "--judge-model"
      judgeModel
      "--improver-model"
      defaultModels.openai
    ];
    configured = pkgs.symlinkJoin {
      name = "${suite.name}-configured";
      paths = [suite];
      nativeBuildInputs = [pkgs.makeWrapper];
      postBuild = ''
        wrapProgram "$out/bin/claude-prompt-conformance" \
          --add-flags ${lib.escapeShellArg (lib.escapeShellArgs configurationFlags)}
      '';
      meta.mainProgram = "claude-prompt-conformance";
    };

    # A patch of the shape an improvement proposal produces. The smoke check
    # below applies it, so a change to the prompt source layout that would stop
    # every proposal applying is caught without a model request.
    variantPatch = pkgs.writeText "prompt-conformance-variant-smoke.patch" ''
      --- a/output-style/plain-technical-prose.md
      +++ b/output-style/plain-technical-prose.md
      @@ -8,3 +8,3 @@

      -# Plain technical prose
      +# Plain technical prose test variant

    '';
    variantSmokeSource = pkgs.applyPatches {
      name = "prompt-conformance-variant-smoke-source";
      src = promptSource;
      patches = [variantPatch];
    };
  in {
    apps.claude-prompt-conformance = {
      type = "app";
      program = lib.getExe configured;
      meta.description = "Test Claude's assembled prompt configuration";
    };

    # The program loads its whole configuration before it lists anything, so
    # `--list` fails as soon as this module and the package stop fitting
    # together. The comparisons below check the fixture catalogue and one
    # assembled rule against the file it came from.
    checks.prompt-conformance-configuration =
      pkgs.runCommandLocal "prompt-conformance-configuration" {
        nativeBuildInputs = [configured pkgs.diffutils pkgs.gnugrep pkgs.jq];
      } ''
        claude-prompt-conformance --list >catalogue.json
        jq --compact-output --sort-keys . catalogue.json >catalogue.normalised.json
        jq --compact-output --sort-keys . ${suite.catalogue} >expected.normalised.json
        cmp catalogue.normalised.json expected.normalised.json
        cmp \
          ${./instructions/claude-code/harness.md} \
          ${promptEnvironment.candidateContext}/rules/harness.md
        grep --fixed-strings --quiet \
          '# Plain technical prose test variant' \
          ${variantSmokeSource}/output-style/plain-technical-prose.md
        touch "$out"
      '';
  };
}
