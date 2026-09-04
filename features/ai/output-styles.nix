# Discover and parse shared output-style files from ./output-style/.
#
# Each file is a complete Claude Code output style: YAML frontmatter with at
# least `name:` and `description:`, then the style text. Claude Code installs
# the files verbatim and selects one by its frontmatter name; every other
# consumer works from the parsed parts. To add a style, drop a new .md file
# in the directory.
#
# Returns { styles, files, default } where:
#   styles  — { stem = { stem, file, name, description, body }; }: `name` and
#             `description` are the frontmatter fields, `body` is the text
#             after the closing delimiter
#   files   — { stem = path; } for programs.claude-code.outputStyles, which
#             installs the files verbatim
#   default — the parsed style that the `outputStyle` setting selects and
#             that harnesses without native output styles receive through
#             their shared instructions. A direct reference into `styles`,
#             so selecting a style that has no file fails evaluation at
#             that line rather than at whichever consumer reads it first.
{lib}: let
  dir = ./output-style;

  # A frontmatter value may fold across several lines, each continuation
  # line starting with whitespace. Join the pieces back into one value.
  fieldValue = file: field: fmLines: let
    start =
      lib.lists.findFirstIndex (lib.hasPrefix "${field}:")
      (throw "output style ${toString file} has no `${field}:` frontmatter field")
      fmLines;

    after = lib.drop (start + 1) fmLines;

    folded =
      lib.lists.findFirstIndex (line: !(lib.hasPrefix " " line))
      (builtins.length after)
      after;

    parts =
      builtins.filter (part: part != "")
      (map lib.trim (
        [(lib.removePrefix "${field}:" (builtins.elemAt fmLines start))]
        ++ lib.take folded after
      ));
  in
    lib.concatStringsSep " " parts;

  parse = stem: file: let
    lines = lib.splitString "\n" (builtins.readFile file);

    close =
      lib.lists.findFirstIndex (line: line == "---")
      (throw "output style ${toString file} has no closing `---` delimiter")
      (builtins.tail lines);

    frontmatter = lib.take close (builtins.tail lines);
  in
    if builtins.head lines != "---"
    then throw "output style ${toString file} does not start with `---` frontmatter"
    else {
      inherit stem file;
      name = fieldValue file "name" frontmatter;
      description = fieldValue file "description" frontmatter;
      body =
        lib.removePrefix "\n"
        (lib.concatStringsSep "\n" (lib.drop (close + 1) (builtins.tail lines)));
    };

  styles =
    lib.mapAttrs'
    (name: _: let
      stem = lib.removeSuffix ".md" name;
    in
      lib.nameValuePair stem (parse stem (dir + "/${name}")))
    (lib.filterAttrs
      (name: type: type == "regular" && lib.hasSuffix ".md" name)
      (builtins.readDir dir));
in {
  inherit styles;

  default = styles.plain-technical-prose;

  files = lib.mapAttrs (_: style: style.file) styles;
}
