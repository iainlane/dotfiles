{
  config,
  inputs,
  lib,
  pkgs,
  username,
  hostConfig,
  ...
}: let
  secretsFile = inputs.secrets + "/${hostConfig.name}/host-user-password.yaml";

  # lib/sops.nix states the policy for a per-host secrets file that the secrets
  # input does not have. When the input has no such file, the account has no
  # password and can be logged into only over SSH.
  havePassword = builtins.pathExists secretsFile;
in {
  boot = {
    loader = {
      systemd-boot = {
        enable = lib.mkDefault true;
        configurationLimit = 10;
      };
      efi.canTouchEfiVariables = true;
    };
    initrd.systemd.enable = true;

    # zfs is unused on these hosts, and the default (`true`) trips an
    # evaluation warning.
    zfs.forceImportRoot = false;
  };

  networking = {
    hostName = hostConfig.hostname;
    networkmanager = {
      enable = true;
      dns = "systemd-resolved";
    };
    nftables.enable = true;
  };

  services.resolved.enable = true;

  time.timeZone = hostConfig.timezone;
  i18n.defaultLocale = hostConfig.locale;

  sops.secrets = lib.optionalAttrs havePassword {
    user-password-hash = {
      sopsFile = secretsFile;
      neededForUsers = true;
    };
  };

  # `extraGroups` below names this group, and only `base.openssh` declares it,
  # so a NixOS host without that feature would fail to evaluate.
  users.groups.ssh = {};

  users.users.${username} = {
    isNormalUser = true;
    home = hostConfig.homeDirectory;
    extraGroups = ["wheel" "networkmanager" "ssh"];
    shell = pkgs.zsh;
    hashedPasswordFile = lib.mkIf havePassword config.sops.secrets.user-password-hash.path;
    openssh.authorizedKeys.keys = import ./authorized-keys.nix;
  };

  programs.zsh.enable = true;

  # envfs and nix-ld let binaries and scripts built for other distributions
  # find `/usr/bin/env` and the dynamic loader that they were linked against.
  services.envfs.enable = true;
  programs.nix-ld.enable = true;

  security = {
    sudo-rs = {
      enable = true;
      extraConfig = ''
        # Don't echo asterisks while typing passwords.
        Defaults !pwfeedback
      '';
    };
    polkit.enable = true;
  };

  nix = {
    settings = {
      experimental-features = ["nix-command" "flakes"];
      keep-outputs = true;
      auto-optimise-store = true;
    };

    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
  };

  system.stateVersion = hostConfig.stateVersion;
}
