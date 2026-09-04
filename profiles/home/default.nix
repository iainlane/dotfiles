# The home feature configures Debian/Ubuntu/GNOME project directories. The
# project directories themselves are Linux-specific, defined in linux.nix.
{config, ...}: let
  inherit (config.flake) features;
in {
  imports = [
    ./linux.nix
  ];

  flake.features.home = {
    includes = [features.cloudflare-mcp features.git];

    homeManager = {
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
