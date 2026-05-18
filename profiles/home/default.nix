# The home profile configures Debian/Ubuntu/GNOME project directories.
# All configuration is Linux-specific, defined in linux.nix.
{
  imports = [
    ./linux.nix
  ];

  flake.profiles.home.homeManagerModule = {
    dotfiles.ssh.matchBlocks = {
      cripps = {
        hostname = "cripps.orangesquash.org.uk";
        user = "laney";
      };

      os = {
        hostname = "cripps.orangesquash.org.uk";
        user = "laney";
      };
    };
  };
}
