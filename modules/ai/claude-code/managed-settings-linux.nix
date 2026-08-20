# Linux/NixOS: write via environment.etc. Used for both NixOS and
# system-manager-linux — both surfaces expose environment.etc.
{
  config,
  pkgs,
  ...
}: let
  settingsFile = import ./managed-settings-file.nix {
    inherit pkgs;
    settings = config.dotfiles.claudeCode.managedSettings;
  };
in {
  imports = [./managed-settings-common.nix];

  environment.etc."claude-code/managed-settings.json".source = settingsFile;
}
