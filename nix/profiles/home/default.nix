# The home profile configures Debian/Ubuntu/GNOME project directories.
# All configuration is Linux-specific, defined in linux.nix.
_: {
  imports = [
    ./linux.nix
  ];

  flake.profiles.home.homeManagerModule = {};
}
