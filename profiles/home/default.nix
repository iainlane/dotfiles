# The home profile configures Debian/Ubuntu/GNOME project directories. The
# project directories themselves are Linux-specific, defined in linux.nix.
_: {
  imports = [
    ./linux.nix
  ];

  flake.profiles.home = {
    features = ["git"];

    homeManagerModule = {
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

      programs.git.settings.sendemail = {
        smtpencryption = "tls";
        smtpserver = "mail.messagingengine.com";
        smtpuser = "laney@fastmail.fm";
        smtpserverport = 587;
        suppresscc = "self";
      };
    };
  };
}
