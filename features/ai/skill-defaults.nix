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
    (name: _: {skill = import (dir + "/${name}");})
    subdirs;

  external = {
    gh-stack.directory = "${inputs.gh-stack-skill}/skills/gh-stack";
  };

  instructions = import ./agent-instructions.nix {inherit lib;};

  outputStyles = import ./output-styles.nix {inherit lib;};

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
  skillDefinitions = local // external // styles;

  normalised = lib.evalModules {
    modules = [
      {
        options.skills = lib.mkOption {
          type = lib.types.attrsOf (import ./skill-type.nix {inherit lib;});
        };
        config.skills = skillDefinitions;
      }
    ];
  };
in {
  inherit instructions outputStyles skillDefinitions;
  skills = normalised.config.skills;
  runtimeDependencies = {
    gh-stack = ["git" "gh" "gh-stack"];
    stacked-prs = ["git" "gh"];
  };
}
