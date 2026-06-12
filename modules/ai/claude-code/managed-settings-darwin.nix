# Darwin: symlink the generated file from /Library. nix-darwin exposes
# `system.activationScripts.postActivation` for this; system-manager
# (linux) does not, which is why this module is gated to darwin only.
{
  config,
  pkgs,
  ...
}: let
  settingsFile =
    (pkgs.formats.json {}).generate "managed-settings.json"
    config.dotfiles.claudeCode.managedSettings;
  darwinPath = "/Library/Application Support/ClaudeCode";
in {
  imports = [./managed-settings-common.nix];

  system.activationScripts.postActivation.text = ''
    mkdir -p '${darwinPath}'
    ln -sf '${settingsFile}' '${darwinPath}/managed-settings.json'
  '';
}
