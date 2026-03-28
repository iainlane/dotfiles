# Discover and expose shared agent instruction files from ./instructions/.
#
# Returns { files, concatenated } where:
#   files        — { stem = path; } for each .md file (for tools that accept
#                  split files, e.g. Claude Code rules, Gemini CLI context)
#   concatenated — single string with AGENTS.md first, then the rest in
#                  lexicographic order (for tools that need one blob, e.g.
#                  Codex, OpenCode)
{lib}: let
  dir = ./instructions;

  # Discover every .md file in the directory.
  mdFiles =
    lib.filterAttrs
    (name: type: type == "regular" && lib.hasSuffix ".md" name)
    (builtins.readDir dir);

  # { stem = ./instructions/<file>.md; }
  files =
    lib.mapAttrs'
    (name: _: lib.nameValuePair (lib.removeSuffix ".md" name) (dir + "/${name}"))
    mdFiles;

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
