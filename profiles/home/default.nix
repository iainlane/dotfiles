# The home profile configures Debian/Ubuntu/GNOME project directories.
# All configuration is Linux-specific, defined in linux.nix.
{
  imports = [
    ./linux.nix
  ];

  flake.profiles.home.homeManagerModule = {
    dotfiles.ssh.settings = {
      cripps = {
        HostName = "cripps.orangesquash.org.uk";
        User = "laney";
      };

      os = {
        HostName = "cripps.orangesquash.org.uk";
        User = "laney";
      };
    };
  };
}
