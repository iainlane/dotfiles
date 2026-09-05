{lib, ...}: {
  programs.ssh = {
    enable = true;

    # Home Manager's own `*` block is deprecated and warns, so repeat its
    # values here. Each directive is a `mkDefault` of its own, so a feature
    # can override one without replacing the block.
    enableDefaultConfig = false;

    settings."*" = lib.mapAttrs (_directive: lib.mkDefault) {
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
}
