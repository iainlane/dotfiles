# Prose linting for every AI harness.
#
# `prose-lint` runs Vale over a file that an agent has just edited, over a
# commit message, or over the files named on its command line. This module installs it
# with Vale and the Vale language server and writes the two configuration
# files that they read. ./README.md describes the rule tiers and how a rule is
# overridden; the Claude Code hooks that call the tool are in
# ./claude-code/managed-settings-common.nix.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.dotfiles.ai.proseLint;

  tomlFormat = pkgs.formats.toml {};
in {
  options.dotfiles.ai.proseLint = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to install `prose-lint`, Vale and the Vale language server,
        and to write their configuration.
      '';
    };

    owners = lib.mkOption {
      type = with lib.types; listOf str;
      default = ["iainlane" "underwhelmingperformance"];
      description = ''
        GitHub users and organisations whose repositories count as the
        user's own. `prose-lint` reports a house-tier rule as an error in a
        repository owned by one of these accounts, and as a warning in every
        other repository.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      pkgs.prose-lint
      pkgs.vale
      pkgs.vale-ls
    ];

    xdg.configFile = {
      # Vale looks for its global configuration under this name, with the
      # leading dot, inside the `vale` configuration directory. A project's
      # own `.vale.ini` is layered over it.
      "vale/.vale.ini".source = "${pkgs.prose-lint}/share/prose-lint/vale.ini";

      "prose-lint/config.toml".source = tomlFormat.generate "prose-lint-config.toml" {
        inherit (cfg) owners;
      };
    };
  };
}
