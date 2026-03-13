{
  config,
  inputs,
  lib,
  pkgs,
  username,
  hostConfig,
  ...
}: let
  secretsFile = inputs.secrets + "/${config.networking.hostName}/host-user-password.yaml";
in {
  boot = {
    loader = {
      systemd-boot.enable = lib.mkDefault true;
      efi.canTouchEfiVariables = true;
    };
    initrd.systemd.enable = true;
  };

  networking = {
    hostName = hostConfig.hostname;
    networkmanager.enable = true;
  };

  time.timeZone = hostConfig.timezone or "Europe/London";
  i18n.defaultLocale = hostConfig.locale or "en_GB.UTF-8";

  sops.secrets.user-password-hash = {
    sopsFile = secretsFile;
    neededForUsers = true;
  };

  users.users.${username} = {
    isNormalUser = true;
    home = hostConfig.homeDirectory;
    extraGroups = ["wheel" "networkmanager"];
    shell = pkgs.zsh;
    hashedPasswordFile = config.sops.secrets.user-password-hash.path;
  };

  programs.zsh.enable = true;

  security = {
    sudo-rs.enable = true;
    polkit.enable = true;
  };

  sops.age.sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];

  nix.settings = {
    experimental-features = ["nix-command" "flakes"];
    keep-outputs = true;
  };

  system.stateVersion = hostConfig.stateVersion;
}
