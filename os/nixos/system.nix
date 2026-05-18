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
      systemd-boot = {
        enable = lib.mkDefault true;
        configurationLimit = 10;
      };
      efi.canTouchEfiVariables = true;
    };
    initrd.systemd.enable = true;
  };

  networking = {
    hostName = hostConfig.hostname;
    networkmanager.enable = true;
    nftables.enable = true;
  };

  time.timeZone = hostConfig.timezone;
  i18n.defaultLocale = hostConfig.locale;

  sops = {
    secrets = {
      user-password-hash = {
        sopsFile = secretsFile;
        neededForUsers = true;
      };
    };
  };

  users.users.${username} = {
    isNormalUser = true;
    home = hostConfig.homeDirectory;
    extraGroups = ["wheel" "networkmanager" "ssh"];
    shell = pkgs.zsh;
    hashedPasswordFile = config.sops.secrets.user-password-hash.path;
    openssh.authorizedKeys.keys = import ./authorized-keys.nix;
  };

  programs.zsh.enable = true;

  # Enable envfs and nix-ld to support non-nixos scripts better.
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
