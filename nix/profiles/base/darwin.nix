# Darwin-specific base configuration
{
  flake.profiles.base.os.darwin.homeManagerModule = {pkgs, ...}: {
    home.packages = with pkgs; [
      ghostty-bin.terminfo
    ];

    targets.darwin = {
      # Copy app bundles to ~/Applications so Spotlight indexes them directly.
      copyApps.enable = true;
      # Disable the old symlink approach (default for stateVersion < 25.11).
      linkApps.enable = false;
    };
  };

  flake.profiles.base.os.darwin.systemManagerModule = {
    imports = [
      ./system-defaults.nix
    ];

    homebrew = {
      enable = true;

      enableZshIntegration = true;

      onActivation = {
        cleanup = "uninstall";
        upgrade = true;
      };
    };
  };
}
