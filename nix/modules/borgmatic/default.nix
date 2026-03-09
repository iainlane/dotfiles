_: let
  nixosModule = {
    config,
    inputs,
    ...
  }: let
    secretsFile = inputs.secrets + "/${config.networking.hostName}/host-borgmatic.yaml";
  in {
    sops.secrets."encryption_passphrase" = {
      sopsFile = secretsFile;
    };

    services.borgmatic = {
      enable = true;
      settings = {
        encryption_passcommand = "cat ${config.sops.secrets."encryption_passphrase".path}";
        source_directories = [
          "/home"
          "/etc"
          "/var/lib"
          "/root"
        ];
        exclude_patterns = [
          "/nix"
          "/tmp"
          "/var/tmp"
          "/var/cache"
          "*/.cache"
          "*/.local/share/Trash"
          "node_modules"
          ".direnv"
          "result"
          "*.pyc"
          "__pycache__"
          "target/debug"
          ".cargo/registry"
        ];
        exclude_caches = true;
        one_file_system = true;
        compression = "auto,zstd";
        retention = {
          keep_daily = 7;
          keep_weekly = 4;
          keep_monthly = 6;
          keep_yearly = 1;
        };
        consistency = {
          checks = [
            {
              name = "repository";
              frequency = "2 weeks";
            }
            {
              name = "archives";
              frequency = "1 month";
            }
          ];
        };
      };
    };

    systemd.timers.borgmatic = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
        RandomizedDelaySec = "1h";
      };
    };
  };
in {
  flake.modules.borgmatic = {
    nixosModules = [nixosModule];
  };
}
