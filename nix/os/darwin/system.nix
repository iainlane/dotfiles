{
  username,
  hostConfig,
  nixCacheSettings,
  ...
}: {
  determinateNix.customSettings = nixCacheSettings;

  sops.age.sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];

  system.primaryUser = username;
  system.stateVersion = 5;

  users.users.${username} = {
    name = username;
    home = hostConfig.homeDirectory;
  };
}
