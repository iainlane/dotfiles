_: let
  # Upstream OpenSSH directive name -> legacy camelCase option name in
  # `programs.ssh.matchBlocks.<host>`. Used to translate consumer-facing
  # configuration back to the legacy shape when only the deprecated
  # `matchBlocks` option is available (home-manager < release 26.05).
  upstreamToLegacy = {
    AddKeysToAgent = "addKeysToAgent";
    Compression = "compression";
    ControlMaster = "controlMaster";
    ControlPath = "controlPath";
    ControlPersist = "controlPersist";
    ForwardAgent = "forwardAgent";
    HashKnownHosts = "hashKnownHosts";
    HostName = "hostname";
    IdentitiesOnly = "identitiesOnly";
    IdentityFile = "identityFile";
    Port = "port";
    ProxyCommand = "proxyCommand";
    ProxyJump = "proxyJump";
    ServerAliveCountMax = "serverAliveCountMax";
    ServerAliveInterval = "serverAliveInterval";
    User = "user";
    UserKnownHostsFile = "userKnownHostsFile";
  };

  toLegacyBlock = lib: block: let
    partitioned =
      lib.partition (k: upstreamToLegacy ? ${k}) (builtins.attrNames block);
    known =
      lib.listToAttrs
      (map (k: lib.nameValuePair upstreamToLegacy.${k} block.${k}) partitioned.right);
    extras =
      lib.listToAttrs
      (map (k: lib.nameValuePair k block.${k}) partitioned.wrong);
  in
    known // lib.optionalAttrs (extras != {}) {extraOptions = extras;};

  homeManagerModule = {
    config,
    lib,
    options,
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

    hasSettings = options.programs.ssh ? settings;
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
      programs.ssh =
        {
          enable = true;
          enableDefaultConfig = false;
          inherit (cfg) includes;
        }
        // (
          if hasSettings
          then {settings = allBlocks;}
          else {matchBlocks = lib.mapAttrs (_: toLegacyBlock lib) allBlocks;}
        );
    };
  };
in {
  flake.modules.ssh = {
    homeManagerModules = [homeManagerModule];
  };
}
