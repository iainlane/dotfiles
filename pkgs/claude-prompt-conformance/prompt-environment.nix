{
  instructions,
  lib,
  managedSettings,
  pkgs,
}: let
  # The instruction set carries file contents; the contexts below link real
  # files, so write each rule back out as one.
  ruleFiles =
    lib.mapAttrs
    (name: content: pkgs.writeText "${name}.md" content)
    instructions.files;

  workspaceOverlay = pkgs.linkFarm "prompt-conformance-workspace-overlay" (
    (lib.mapAttrsToList (name: path: {
        name = ".claude/rules/${name}.md";
        inherit path;
      })
      ruleFiles)
    ++ (lib.mapAttrsToList (name: style: {
        name = ".claude/output-styles/${name}.md";
        path = style.file;
      })
      instructions.outputStyles)
  );
  managedSettingsFile =
    pkgs.writeText "prompt-conformance-settings.json"
    (builtins.toJSON managedSettings);
  promptContext =
    pkgs.writeText "prompt-conformance-context.json"
    (builtins.toJSON {
      globalPrompt = instructions.files;
      outputStyles =
        lib.mapAttrs (_: style: {
          inherit (style) name;
          content = builtins.readFile style.file;
        })
        instructions.outputStyles;
      defaultOutputStyle = managedSettings.outputStyle;
    });
  candidateContext = pkgs.linkFarm "prompt-conformance-candidate-context" (
    [
      {
        name = "manifest.json";
        path = promptContext;
      }
      {
        name = "managed-settings.json";
        path = managedSettingsFile;
      }
    ]
    ++ (lib.mapAttrsToList (name: path: {
        name = "rules/${name}.md";
        inherit path;
      })
      ruleFiles)
    ++ (lib.mapAttrsToList (name: style: {
        name = "output-styles/${name}.md";
        path = style.file;
      })
      instructions.outputStyles)
  );
  # The part of the run metadata that identifies the prompt. A variant recomputes
  # it from its own instruction set and keeps the rest of the base metadata.
  promptDigests = {
    prompt =
      lib.mapAttrs (_: content: builtins.hashString "sha256" content)
      instructions.files;
    outputStyles =
      lib.mapAttrs (_: style: builtins.hashFile "sha256" style.file)
      instructions.outputStyles;
    defaultOutputStyle = managedSettings.outputStyle;
  };
in {
  inherit
    candidateContext
    managedSettingsFile
    promptContext
    promptDigests
    workspaceOverlay
    ;
}
