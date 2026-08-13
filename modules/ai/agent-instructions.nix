# Discover and expose shared agent instruction files from ./instructions/.
#
# Each harness can also carry its own extra instructions: any .md files in
# the subdirectory matching the importing module's name (crush.nix ->
# ./instructions/crush/, claude-code/home-manager.nix ->
# ./instructions/claude-code/, pi/default.nix -> ./instructions/pi/) are
# discovered and merged over the shared set, so a harness gains instructions
# -- or overrides a shared file by reusing its stem -- just by dropping files
# there. The module is identified from the source position of the caller's
# argument set, so nothing needs to be passed explicitly.
#
# The default output style (see ./output-styles.nix) is part of the shared
# set: a harness with no native style support receives the style body as an
# ordinary instruction. Claude Code selects the style through its settings
# instead, and passes `nativeOutputStyles = true` here to keep the body out
# of its instructions; the model would otherwise receive the same text
# twice.
#
# Returns { files, concatenated } where:
#   files        — { stem = content; } for each instruction (for tools that
#                  accept split files, e.g. Claude Code rules, Antigravity
#                  context)
#   concatenated — single string with AGENTS.md first, then the rest in
#                  lexicographic order (for tools that need one blob, e.g.
#                  Codex, OpenCode)
args @ {
  lib,
  nativeOutputStyles ? false,
}: let
  dir = ./instructions;

  outputStyles = import ./output-styles.nix {inherit lib;};

  # The file that wrote `{inherit lib;}` is the importing harness module.
  callerPos = builtins.unsafeGetAttrPos "lib" args;

  harness =
    if callerPos == null
    then null
    else let
      stem = lib.removeSuffix ".nix" (baseNameOf callerPos.file);
    in
      if stem == "default" || stem == "home-manager"
      then baseNameOf (dirOf callerPos.file)
      else stem;

  # { stem = file content; } for every .md file directly under a directory.
  filesIn = d:
    lib.mapAttrs'
    (name: _: lib.nameValuePair (lib.removeSuffix ".md" name) (builtins.readFile (d + "/${name}")))
    (lib.filterAttrs
      (name: type: type == "regular" && lib.hasSuffix ".md" name)
      (builtins.readDir d));

  defaultStyle =
    lib.optionalAttrs (!nativeOutputStyles)
    {${outputStyles.default.stem} = outputStyles.default.body;};

  harnessFiles =
    lib.optionalAttrs
    (harness != null && builtins.pathExists (dir + "/${harness}"))
    (filesIn (dir + "/${harness}"));

  files = filesIn dir // defaultStyle // harnessFiles;

  # AGENTS first, then remaining stems in lexicographic order.
  otherStems =
    lib.sort (a: b: a < b)
    (builtins.filter (s: s != "AGENTS") (lib.attrNames files));
  order = ["AGENTS"] ++ otherStems;

  concatenated =
    lib.concatMapStringsSep "\n\n"
    (stem: files.${stem})
    order;
in {
  inherit files concatenated;
}
