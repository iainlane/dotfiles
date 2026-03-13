_: let
  homeManagerModule = {
    config,
    lib,
    ...
  }: {
    options.dotfiles.ssh = {
      includes = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
      };
      matchBlocks = lib.mkOption {
        type = lib.types.attrsOf lib.types.unspecified;
        default = {};
      };
    };

    config = {
      programs.ssh = {
        enable = true;
        enableDefaultConfig = false;
        inherit (config.dotfiles.ssh) includes;
        matchBlocks =
          {
            "*" = {
              forwardAgent = false;
              addKeysToAgent = "no";
              compression = false;
              serverAliveInterval = 0;
              serverAliveCountMax = 3;
              hashKnownHosts = false;
              userKnownHostsFile = "~/.ssh/known_hosts";
              controlMaster = "no";
              controlPath = "~/.ssh/master-%r@%n:%p";
              controlPersist = "no";
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
