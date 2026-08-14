# Discover and expose shared agent instruction files from ./instructions/.
#
# Harnesses can also carry extra instructions. Named instruction sets merge
# their harness directory over the shared files, so reusing a stem overrides
# the shared file for that harness.
#
# The default output style (see ./output-styles.nix) is part of the shared
# set: a harness with no native style support receives the style body as an
# ordinary instruction. Claude Code installs the styles natively and selects
# one through its settings, so its instruction set leaves the body out; the
# model would otherwise receive the same text twice.
#
# Returns { files, concatenated, outputStyles, harnesses } where:
#   files        — { stem = content; } for each instruction (for tools that
#                  accept split files, e.g. Claude Code rules, Antigravity
#                  context)
#   concatenated — single string with AGENTS.md first, then the rest in
#                  lexicographic order (for tools that need one blob, e.g.
#                  Codex, OpenCode)
#   outputStyles — { stem = parsed style; } from ./output-styles.nix
#   harnesses    — named instruction sets with harness-specific files merged
{
  lib,
  source ? ./.,
}: let
  dir = source + "/instructions";

  outputStyles = import (source + "/output-styles.nix") {inherit lib;};

  # { stem = file content; } for every .md file directly under a directory.
  filesIn = d:
    lib.mapAttrs'
    (name: _: lib.nameValuePair (lib.removeSuffix ".md" name) (builtins.readFile (d + "/${name}")))
    (lib.filterAttrs
      (name: type: type == "regular" && lib.hasSuffix ".md" name)
      (builtins.readDir d));

  makeInstructionSet = {
    harnessDirectory ? null,
    nativeOutputStyles ? false,
  }: let
    defaultStyle =
      lib.optionalAttrs (!nativeOutputStyles)
      {${outputStyles.default.stem} = outputStyles.default.body;};

    harnessFiles =
      lib.optionalAttrs (harnessDirectory != null)
      (filesIn harnessDirectory);

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
    outputStyles = outputStyles.styles;
  };
in
  makeInstructionSet {}
  // {
    harnesses.claudeCode = makeInstructionSet {
      harnessDirectory = dir + "/claude-code";
      nativeOutputStyles = true;
    };
  }
