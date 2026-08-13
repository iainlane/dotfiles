# Discover and expose shared skill directories from ./skills/, plus skills
# published in external repositories and consumed as flake inputs.
#
# Every shared output style (see ./output-styles.nix) also becomes a skill,
# so the user can adopt a style mid-session in any harness by invoking the
# skill named after the style's stem.
#
# Returns { name = <directory path or SKILL.md content>; } for each skill,
# suitable for passing directly to programs.<tool>.skills.
{
  inputs,
  lib,
}: let
  dir = ./skills;

  subdirs =
    lib.filterAttrs
    (_name: type: type == "directory")
    (builtins.readDir dir);

  local =
    lib.mapAttrs
    (name: _: dir + "/${name}")
    subdirs;

  external = {
    gh-stack = "${inputs.gh-stack-skill}/skills/gh-stack";
  };

  outputStyles = import ./output-styles.nix {inherit lib;};

  # The preamble tells the model to adopt the style from this point on; the
  # style body follows verbatim.
  styleSkill = stem: style: ''
    ---
    name: ${stem}
    description: Adopt the ${style.name} output style (${style.description}). Use when the user asks for output in this style.
    ---

    The user asked for the ${style.name} output style. Apply the style below
    to all prose you write for the rest of the session. This style replaces
    any output style that was active before; all other instructions still
    apply.

    ${style.body}'';

  styles = lib.mapAttrs styleSkill outputStyles.styles;
in
  local // external // styles
