# Debian/Ubuntu/GNOME project directories - Linux only.
#
# This is a flake-parts module that exports shells for all systems (they're just
# derivations) but only configures the project directories on Linux hosts.
{
  inputs,
  config,
  withSystem,
  ...
}: let
  helpers = import ../helpers.nix {inherit inputs;};
  inherit (inputs.nixpkgs) lib;

  projects = let
    defaults = {
      name = "Iain Lane";
      debsignKeyId = "0xE352D5C51C5041D4";
    };
  in {
    dev-debian =
      defaults
      // {
        directory = "dev/debian";
        email = "laney@debian.org";
        debVendor = "Debian";
        zshColour = "red";
      };

    dev-ubuntu =
      defaults
      // {
        directory = "dev/ubuntu";
        email = "laney@ubuntu.com";
        debVendor = "Ubuntu";
        zshColour = "yellow";
      };

    dev-gnome =
      defaults
      // {
        directory = "dev/gnome";
        email = "iainl@gnome.org";
        debVendor = "Ubuntu";
        zshColour = "green";
      };
  };

  mkShell = pkgs: _os: def:
    pkgs.mkShell (
      {
        packages = def.packages or (_: []) pkgs;
      }
      // {
        NAME = def.name;
        EMAIL = def.email;
        DEBFULLNAME = def.name;
        DEBEMAIL = def.email;
        DEBSIGN_KEYID = def.debsignKeyId;
        GIT_AUTHOR_NAME = def.name;
        GIT_AUTHOR_EMAIL = def.email;
        GIT_COMMITTER_EMAIL = def.email;
      }
      // lib.optionalAttrs (def.debVendor != null) {DEB_VENDOR = def.debVendor;}
      // lib.optionalAttrs (def ? zshColour && def.zshColour != null) {
        ZSH_USERNAME_COLOUR = def.zshColour;
      }
    );

  projectShells = helpers.mkProjectShells {
    inherit config withSystem mkShell projects;
  };
in {
  imports = [projectShells.flakeModule];
  flake.profiles.home.os.linux.homeManagerModule = {config, ...} @ args:
    lib.recursiveUpdate
    (projectShells.homeManagerModule args)
    {
      home.sessionPath = [
        "${config.home.homeDirectory}/bin/ubuntu-dev-tools"
        "${config.home.homeDirectory}/bin/ubuntu-archive-tools"
      ];

      programs = {
        git.settings = {
          merge."dpkg-mergechangelogs" = {
            name = "debian/changelog merge driver";
            driver = "dpkg-mergechangelogs -m %O %A %B %A";
          };

          # Git URL shortcuts.

          # Allow gnome:<path> shorthand for SSH URLs; also rewrite git:// to
          # SSH for pushes.
          "url \"ssh://git.gnome.org/git/\"" = {
            insteadOf = "gnome:";
            pushInsteadOf = "git://git.gnome.org/git/";
          };

          # lp: shorthand for Launchpad Git URLs.
          "url \"git+ssh://laney@git.launchpad.net/\"".insteadOf = "lp:";
        };

        zsh.sessionVariables = {
          QUILT_PATCHES = "debian/patches";
        };
      };

      xdg.configFile."zsh/functions".source = ../../modules/zsh/functions;
    };
}
