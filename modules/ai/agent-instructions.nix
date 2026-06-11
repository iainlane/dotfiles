# Discover and expose shared agent instruction files from ./instructions/.
#
# Each harness can also carry its own extra instructions: any .md files in
# the subdirectory matching the importing module's name (claude-code.nix ->
# ./instructions/claude-code/, pi/default.nix -> ./instructions/pi/) are
# discovered and merged over the shared set, so a harness gains instructions
# -- or overrides a shared file by reusing its stem -- just by dropping files
# there. The module is identified from the source position of the caller's
# argument set, so nothing needs to be passed explicitly.
#
# Returns { files, concatenated } where:
#   files        — { stem = path; } for each .md file (for tools that accept
#                  split files, e.g. Claude Code rules, Gemini CLI context)
#   concatenated — single string with AGENTS.md first, then the rest in
#                  lexicographic order (for tools that need one blob, e.g.
#                  Codex, OpenCode)
args @ {lib}: let
  dir = ./instructions;

  # The file that wrote `{inherit lib;}` is the importing harness module.
  callerPos = builtins.unsafeGetAttrPos "lib" args;

  harness =
    if callerPos == null
    then null
    else let
      stem = lib.removeSuffix ".nix" (baseNameOf callerPos.file);
    in
      if stem == "default"
      then baseNameOf (dirOf callerPos.file)
      else stem;

  # { stem = <d>/<file>.md; } for every .md file directly under a directory.
  filesIn = d:
    lib.mapAttrs'
    (name: _: lib.nameValuePair (lib.removeSuffix ".md" name) (d + "/${name}"))
    (lib.filterAttrs
      (name: type: type == "regular" && lib.hasSuffix ".md" name)
      (builtins.readDir d));

  harnessFiles =
    lib.optionalAttrs
    (harness != null && builtins.pathExists (dir + "/${harness}"))
    (filesIn (dir + "/${harness}"));

  files = filesIn dir // harnessFiles;

  # AGENTS first, then remaining stems in lexicographic order.
  otherStems =
    lib.sort (a: b: a < b)
    (builtins.filter (s: s != "AGENTS") (lib.attrNames files));
  order = ["AGENTS"] ++ otherStems;

  concatenated =
    lib.concatMapStringsSep "\n\n"
    (stem: builtins.readFile files.${stem})
    order;
in {
  inherit files concatenated;
}
