_: let
  homeManagerModule = {
    config,
    lib,
    ...
  }: {
    options.dotfiles.ssh.matchBlocks = lib.mkOption {
      type = lib.types.attrsOf lib.types.unspecified;
      default = {};
    };

    config = {
      home.file.".ssh/config".force = true;

      # This fragment was created manually while bootstrapping nixbuild admin
      # access. Remove it once Home Manager owns the equivalent match block.
      home.activation.removeLegacyNixbuildAdmin = lib.hm.dag.entryBefore ["checkLinkTargets"] ''
        rm -f "$HOME/.ssh/config.d/nixbuild-admin.conf"
      '';

      programs.ssh = {
        enable = true;
        includes = [
          "~/.orbstack/ssh/config"
          "~/.ssh/config.d/*"
        ];
        matchBlocks =
          {
            "*.debian.org syklone.ubuntuwire.org".serverAliveInterval = 240;

            cripps = {
              hostname = "cripps.orangesquash.org.uk";
              user = "laney";
            };

            os = {
              hostname = "cripps.orangesquash.org.uk";
              user = "laney";
            };

            "ha.home.orangesquash.org.uk" = {
              hostname = "ha.home.orangesquash.org.uk";
              user = "root";
            };
          }
          // config.dotfiles.ssh.matchBlocks;
      };
    };
  };
in {
  flake.modules.ssh = {
    homeManagerModules = [homeManagerModule];
  };
}
