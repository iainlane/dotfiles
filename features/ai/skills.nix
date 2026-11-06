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
  defaults = import ./skill-defaults.nix {inherit inputs lib;};
  inherit (defaults) instructions outputStyles;

  skillTree = import ./skill-tree.nix {inherit lib pkgs;};
  runtimePackages =
    pkgs-unstable
    // {inherit (inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}) agentsview;}
    // lib.optionalAttrs config.programs.git.enable {git = config.programs.git.package;}
    // lib.optionalAttrs config.programs.gh.enable {gh = config.programs.gh.package;};
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

    bundles = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options.skills = lib.mkOption {
          type = lib.types.attrsOf (import ./skill-type.nix {inherit lib;});
          default = {};
          description = "Skills in the bundle. They are merged into dotfiles.ai.skills.";
        };
      });
    };

    skillRuntimeDependencies = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = {};
      description = "Nix package attributes required by each entry in dotfiles.ai.skills. Consumers may replace a package with a compatible broker for their execution environment.";
    };
  };

  config = {
    dotfiles.ai = {
      skills = lib.mkMerge ([defaults.skillDefinitions] ++ lib.mapAttrsToList (_: bundle: bundle.skills) config.dotfiles.ai.bundles);

      skillRuntimeDependencies = defaults.runtimeDependencies;
    };

    home.packages = let
      dependencies = lib.unique (lib.concatLists (lib.attrValues (lib.filterAttrs (name: _: builtins.hasAttr name config.dotfiles.ai.skills) config.dotfiles.ai.skillRuntimeDependencies)));
    in
      map (name: lib.attrByPath (lib.splitString "." name) (throw "Unknown skill runtime package: ${name}") runtimePackages) dependencies;

    home.file.".agents/skills" = {
      source = skillTree {skills = config.dotfiles.ai.skills;};
      recursive = true;
    };

    _module.args = {
      inherit instructions outputStyles skillTree;
      skillRuntimePackages = runtimePackages;
    };
  };
}
