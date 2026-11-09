{
  config,
  inputs,
  lib,
  pkgs,
  pkgs-unstable,
  username,
  hostConfig,
  ...
}: let
  secretsFile = inputs.secrets + "/${hostConfig.name}/host-user-password.yaml";
  stableEnvfs = inputs.nixpkgs-stable.legacyPackages.${pkgs.stdenv.hostPlatform.system}.envfs;

  # A machine that has not been through `scripts/generate-user-secrets.bash`
  # has no password file in the secrets input, and it must still evaluate so
  # that it can be built. Until then the account has no password, and the user
  # can log in only over SSH with a key. lib/sops.nix follows the same rule for
  # the other per-host secrets.
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

  users.users.${username} = {
    isNormalUser = true;
    home = hostConfig.homeDirectory;
    extraGroups = ["wheel" "networkmanager"];
    shell = pkgs.zsh;
    hashedPasswordFile = lib.mkIf havePassword config.sops.secrets.user-password-hash.path;
    openssh.authorizedKeys.keys = import ./authorized-keys.nix;
  };

  programs.zsh.enable = true;

  # envfs and nix-ld let binaries and scripts built for other distributions
  # find `/usr/bin/env` and the dynamic loader that they were linked against.
  services.envfs = {
    enable = true;
    package = assert lib.assertMsg (lib.versionOlder stableEnvfs.version "1.2.0") ''
      envfs ${stableEnvfs.version} from nixpkgs-stable includes the deadlock fix.
      Remove the services.envfs.package override in os/nixos/system.nix.
    '';
      pkgs-unstable.envfs;
  };
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
