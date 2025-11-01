{
  pkgs,
  username,
  hostConfig,
  substitutersCustomConf,
  ...
}: {
  imports = [
    ./system-defaults.nix
    ../../modules/nix/substituters.nix
  ];
  # Disable nix-darwin's daemon management; Determinate Nix handles this.
  nix.enable = false;

  environment.etc = {
    "nix/nix.custom.conf".text = substitutersCustomConf;
  };

  environment.systemPackages = [pkgs.defaultbrowser];

  homebrew = {
    enable = true;

    onActivation = {
      cleanup = "uninstall";
      upgrade = true;
    };

    casks = [
      "google-chrome"
      "orbstack"
      "warp"
      "wine-stable"
    ];
  };

  system.primaryUser = username;
  system.stateVersion = 5;

  users.users.${username} = {
    name = username;
    home = hostConfig.homeDirectory;
  };
}
