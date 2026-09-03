# Skills for every AI harness.
#
# `dotfiles.ai.skills` is the shared set: the directories under ./skills/,
# skills published in external repositories and consumed as flake inputs,
# and one skill per shared output style (see ./output-styles.nix), so the
# user can adopt a style mid-session in any harness by invoking the skill
# named after the style's stem. A profile adds skills of its own with
# ordinary module merging.
#
# `skillTree` assembles a set of skills into one directory. The shared set
# is linked into `~/.agents/skills`, the harness-neutral location. A harness
# that reads only its own directory links the tree itself, through the
# `skillTree` module argument.
#
# A value in the set is inline SKILL.md content, a directory that is a
# skill, or a directory that contains skills. Evaluation cannot tell the
# last two apart, because the contents of a store path are not readable
# until it is built, so each value first becomes a directory of skills in a
# build of its own, which looks for `SKILL.md` at the top of the directory.
# The key names a single skill. For a directory of skills the key is
# ignored: the Agent Skills format requires a skill's `name` to match its
# directory name. `buildEnv` then merges those directories, and aborts the
# build when two skills with one name differ.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
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

  isDirectory = skill: builtins.isPath skill || lib.hasPrefix "/" skill;

  asSkillDirectory = name: skill:
    if isDirectory skill
    then
      pkgs.runCommandLocal "skills-${name}" {source = "${skill}";} ''
        if [ -e "$source/SKILL.md" ]; then
          mkdir "$out"
          ln -s "$source" "$out"/${lib.escapeShellArg name}
        else
          ln -s "$source" "$out"
        fi
      ''
    else pkgs.writeTextDir "${name}/SKILL.md" skill;

  skillTree = skills:
    pkgs.buildEnv {
      name = "skills";
      paths = lib.mapAttrsToList asSkillDirectory skills;
    };
in {
  options.dotfiles.ai.skills = lib.mkOption {
    type = with lib.types; attrsOf (either path str);
    default = {};
    description = ''
      Skills for every AI harness, keyed by skill name. A value is a skill
      directory containing SKILL.md, the SKILL.md content itself, or a
      directory of skill directories. For a directory of skills the key is
      ignored and each skill keeps its own directory name.
    '';
  };

  config = {
    dotfiles.ai.skills = local // external // styles;

    home.file.".agents/skills" = {
      source = skillTree config.dotfiles.ai.skills;
      recursive = true;
    };

    _module.args = {inherit skillTree;};
  };
}
