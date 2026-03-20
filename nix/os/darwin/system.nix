{
  username,
  hostConfig,
  nixCacheSettings,
  ...
}: {
  determinateNix.customSettings = nixCacheSettings;

  system.primaryUser = username;
  system.stateVersion = 5;

  users.users.${username} = {
    name = username;
    home = hostConfig.homeDirectory;
  };
}
