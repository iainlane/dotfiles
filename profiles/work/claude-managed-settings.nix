{
  inputs,
  pkgs,
  ...
}: {
  dotfiles.claudeCode.managedSettings =
    inputs.claude-managed-settings.lib.settings.forSystem
    pkgs.stdenv.hostPlatform.system;
}
