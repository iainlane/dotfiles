# Linux/NixOS: write via environment.etc. Used for both NixOS and
# system-manager-linux — both surfaces expose environment.etc.
{
  config,
  pkgs,
  ...
}: {
  imports = [./managed-settings-common.nix];

  environment.etc."claude-code/managed-settings.json".source =
    (pkgs.formats.json {}).generate "managed-settings.json"
    config.dotfiles.claudeCode.managedSettings;
}
