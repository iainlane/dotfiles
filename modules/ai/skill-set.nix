# Declare the shared skill set as an option, so profiles can add skills of
# their own next to the base set from ./skills.nix.
{
  inputs,
  lib,
  ...
}: {
  options.dotfiles.ai.skills = lib.mkOption {
    type = with lib.types; attrsOf (either path str);
    default = {};
    description = ''
      Skills for every AI harness, keyed by skill name. A value is either a
      skill directory containing SKILL.md, or the SKILL.md content itself.
    '';
  };

  config.dotfiles.ai.skills = import ./skills.nix {inherit inputs lib;};
}
