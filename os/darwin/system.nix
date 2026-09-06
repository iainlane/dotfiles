{
  username,
  hostConfig,
  nixCacheSettings,
  ...
}: {
  determinateNix.customSettings = nixCacheSettings;

  # nix-darwin runs `systemsetup -settimezone` for this during activation, and
  # does nothing when the host record leaves it null.
  time.timeZone = hostConfig.timezone;

  # macOS has no system-wide default locale to set: each login session takes
  # its locale from the user's Language & Region settings. `LANG` is written to
  # the environment file that /etc/zshenv and /etc/bashrc source, so shells and
  # the programs they start use the locale the host record specifies.
  environment.variables.LANG = hostConfig.locale;

  system.primaryUser = username;
  system.stateVersion = 5;

  users.users.${username} = {
    name = username;
    home = hostConfig.homeDirectory;
  };
}
