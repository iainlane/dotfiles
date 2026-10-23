# Skills for every AI harness.
#
# `dotfiles.ai.skills` is the shared set: the skills defined under ./skills/,
# skills published in external repositories and consumed as flake inputs,
# and one skill per shared output style (see ./output-styles.nix), so the
# user can adopt a style mid-session in any harness by invoking the skill
# named after the style's stem. A feature adds skills of its own with
# ordinary module merging. Each directory under ./skills/ has a `default.nix`
# with the skill's definition (see ./skill-type.nix).
#
# The shared instruction set (./agent-instructions.nix) and the parsed output
# styles (./output-styles.nix) are supplied to the harness modules as the
# module arguments `instructions` and `outputStyles`, beside `skillTree` and
# `mcp`. System modules do not receive Home Manager module arguments, so
# `claude-code/managed-settings-common.nix` imports `output-styles.nix`
# directly.
#
# `skillTree` (see ./skill-tree.nix) assembles a set of skills into one
# directory, leaving out any skill named in `excludes`. The shared set is
# linked into `~/.agents/skills`, the harness-neutral location. A harness that
# reads only its own directory links the tree itself, through the `skillTree`
# module argument, and that is where it drops unwanted skills.
{
  config,
  inputs,
  lib,
  pkgs,
  pkgs-unstable,
  ...
}: let
  dir = ./skills;

  subdirs =
    lib.filterAttrs
    (_name: type: type == "directory")
    (builtins.readDir dir);

  local =
    lib.mapAttrs
    (name: _: {skill = import (dir + "/${name}");})
    subdirs;

  external = {
    gh-stack.directory = "${inputs.gh-stack-skill}/skills/gh-stack";
  };

  instructions = import ./agent-instructions.nix {inherit lib;};

  outputStyles = import ./output-styles.nix {inherit lib;};

  # The preamble tells the model to adopt the style from this point on; the
  # style body follows verbatim.
  styleSkill = stem: style: {
    skill = {
      frontmatter.description = "Adopt the ${style.name} output style (${style.description}). ${
        if stem == outputStyles.default.stem
        then "Use when writing or auditing comments, commit messages, documentation or any prose that goes into a repository, and whenever the user asks for this style."
        else "Use when the user asks for output in this style."
      }";

      body = ''
        Apply the ${style.name} output style below to all prose you write for the
        rest of the session. This style replaces any output style that was active
        before; all other instructions still apply.

        ${style.body}'';
    };
  };

  styles = lib.mapAttrs styleSkill outputStyles.styles;

  skillTree = import ./skill-tree.nix {inherit lib pkgs;};
in {
  options.dotfiles.ai = {
    skills = lib.mkOption {
      type = lib.types.attrsOf (import ./skill-type.nix {inherit lib;});
      default = {};
      description = ''
        Skills for every AI harness, keyed by skill name. A value is either a
        `skill` defined in Nix or a `directory` that contains one or more
        skills.
      '';
    };

    skillRuntimeDependencies = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = {};
      description = "Nix package attributes required by each entry in dotfiles.ai.skills. Consumers may replace a package with a compatible broker for their execution environment.";
    };
  };

  config = {
    dotfiles.ai = {
      skills = local // external // styles;

      skillRuntimeDependencies = {
        gh-stack = ["git" "gh" "gh-stack"];
        stacked-prs = ["git" "gh"];
      };
    };

    home.packages = let
      runtimePackages =
        pkgs-unstable
        // {inherit (inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}) agentsview;}
        // lib.optionalAttrs config.programs.git.enable {git = config.programs.git.package;}
        // lib.optionalAttrs config.programs.gh.enable {gh = config.programs.gh.package;};
      dependencies = lib.unique (lib.concatLists (lib.attrValues (lib.filterAttrs (name: _: builtins.hasAttr name config.dotfiles.ai.skills) config.dotfiles.ai.skillRuntimeDependencies)));
    in
      map (name: lib.attrByPath (lib.splitString "." name) (throw "Unknown skill runtime package: ${name}") runtimePackages) dependencies;

    home.file.".agents/skills" = {
      source = skillTree {skills = config.dotfiles.ai.skills;};
      recursive = true;
    };

    _module.args = {inherit instructions outputStyles skillTree;};
  };
}
