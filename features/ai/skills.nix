# Skills for every AI harness.
#
# `dotfiles.ai.skills` is the shared set: the directories under ./skills/,
# skills published in external repositories and consumed as flake inputs,
# and one skill per shared output style (see ./output-styles.nix), so the
# user can adopt a style mid-session in any harness by invoking the skill
# named after the style's stem. A feature adds skills of its own with
# ordinary module merging.
#
# The shared instruction set (./agent-instructions.nix) and the parsed output
# styles (./output-styles.nix) are supplied to the harness modules as the
# module arguments `instructions` and `outputStyles`, beside `skillTree` and
# `mcp`. System modules do not receive Home Manager module arguments, so
# `claude-code/managed-settings-common.nix` imports `output-styles.nix`
# directly.
#
# `skillTree` assembles a set of skills into one directory, leaving out any
# skill named in `excludes`. The shared set is linked into `~/.agents/skills`,
# the harness-neutral location. A harness that reads only its own directory
# links the tree itself, through the `skillTree` module argument, and that is
# where it drops unwanted skills.
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

  instructions = import ./agent-instructions.nix {inherit lib;};

  outputStyles = import ./output-styles.nix {inherit lib;};

  # The preamble tells the model to adopt the style from this point on; the
  # style body follows verbatim.
  styleSkill = stem: style: ''
    ---
    name: ${stem}
    description: Adopt the ${style.name} output style (${style.description}). ${
      if stem == outputStyles.default.stem
      then "Use when writing or auditing comments, commit messages, documentation or any prose that goes into a repository, and whenever the user asks for this style."
      else "Use when the user asks for output in this style."
    }
    ---

    Apply the ${style.name} output style below to all prose you write for the
    rest of the session. This style replaces any output style that was active
    before; all other instructions still apply.

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

  # The excluded names are checked against the merged tree, after the build,
  # because a directory of skills only reveals its names once it is built. A
  # name that matches nothing fails the build, so a stale exclusion cannot
  # linger after a skill is renamed or removed.
  skillTree = {
    skills,
    excludes ? [],
  }:
    pkgs.buildEnv {
      name = "skills";
      paths = lib.mapAttrsToList asSkillDirectory skills;

      postBuild =
        lib.concatMapStringsSep "\n" (name: ''
          if [ ! -e "$out"/${lib.escapeShellArg name} ]; then
            echo "skill exclusion ${name} matches no skill in the tree" >&2
            exit 1
          fi

          rm -r "$out"/${lib.escapeShellArg name}
        '')
        excludes;
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
      source = skillTree {skills = config.dotfiles.ai.skills;};
      recursive = true;
    };

    _module.args = {inherit instructions outputStyles skillTree;};
  };
}
