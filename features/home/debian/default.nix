# The Debian, Ubuntu and GNOME project directories.
#
# The shells are derivations, so this flake-parts module exports them for
# every system. `home` lists this child only on generic-linux hosts, so only
# those get the project directories.
{
  inputs,
  config,
  withSystem,
  ...
}: let
  helpers = import ../../../lib/helpers.nix {inherit inputs;};
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

  flake.features.home.provides.debian.homeManager = [
    projectShells.homeManagerModule
    ./home-manager.nix
  ];
}
