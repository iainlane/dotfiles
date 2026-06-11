_: let
  homeManagerModule = {
    config,
    lib,
    ...
  }: let
    cfg = config.dotfiles.ssh;

    defaultBlock = {
      "*" = {
        ForwardAgent = false;
        AddKeysToAgent = "no";
        Compression = false;
        ServerAliveInterval = 0;
        ServerAliveCountMax = 3;
        HashKnownHosts = false;
        UserKnownHostsFile = "~/.ssh/known_hosts";
        ControlMaster = "no";
        ControlPath = "~/.ssh/master-%r@%n:%p";
        ControlPersist = "no";
      };
    };

    allBlocks = defaultBlock // cfg.settings;
  in {
    options.dotfiles.ssh = {
      includes = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
      };
      settings = lib.mkOption {
        type = lib.types.attrsOf lib.types.unspecified;
        default = {};
      };
    };

    config = {
      programs.ssh = {
        enable = true;
        enableDefaultConfig = false;
        inherit (cfg) includes;
        settings = allBlocks;
      };
    };
  };
in {
  flake.modules.ssh = {
    homeManagerModules = [homeManagerModule];
  };
}
