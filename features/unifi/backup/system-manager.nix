# Scheduled, encrypted backups of the UniFi controller's configuration to
# Cloudflare R2, with a timed check that they are arriving.
#
# The site configuration and the adoption keys of every device live in the
# controller's mongodb database, and a rebuilt controller cannot reproduce
# them: every device would have to be adopted again. The backup unit asks the
# controller, through its API, to write a backup file of its own, so the
# controller keeps running throughout.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = config.dotfiles.unifi;

  container = "unifi-os";

  unit = "unifi-backup";

  site = "default";

  apiKeySecret = "unifi_api_key";

  envTemplate = "unifi-backup.env";
  apiKeyTemplate = "unifi-backup-api-key.env";

  secretsFile = inputs.secrets + "/${cfg.backup.secretsFile}";
  apiKeySecretsFile = inputs.secrets + "/${cfg.secretsFile}";

  apiKeyPresent =
    builtins.pathExists apiKeySecretsFile
    && lib.any
    (line: lib.hasPrefix "${apiKeySecret}:" line)
    (lib.splitString "\n" (builtins.readFile apiKeySecretsFile));

  r2Backup = import ../../../lib/r2-backup.nix;
  r2Tool = r2Backup.tool {inherit pkgs;};

  backupScript = pkgs.writeShellApplication {
    name = "unifi-backup-r2";
    runtimeInputs = with pkgs; [coreutils curl jq r2Tool];
    text = builtins.readFile ./backup.sh;
  };
in {
  config = lib.mkMerge [
    {
      assertions =
        r2Backup.assertions {
          inherit lib secretsFile;
          secretsPath = cfg.backup.secretsFile;
          subject = "The UniFi controller's configuration";
        }
        ++ [
          {
            assertion = apiKeyPresent;
            message = ''
              The UniFi controller is backed up through its API, and
              ${cfg.secretsFile} in the secrets repository has no
              ${apiKeySecret}. Create a key on the Network application's
              Integrations page and add it under that name.
            '';
          }
        ];

      sops = lib.mkMerge [
        (r2Backup.sopsFragment {
          inherit config secretsFile;
          templateName = envTemplate;
        })

        {
          secrets.${apiKeySecret}.sopsFile = apiKeySecretsFile;

          templates.${apiKeyTemplate}.content = ''
            UNIFI_API_KEY=${config.sops.placeholder.${apiKeySecret}}
          '';
        }
      ];

      systemd.services.${unit} = {
        description = "Back the UniFi controller's configuration up to Cloudflare R2";
        requires = ["${container}.service" "sops-install-secrets.service"];
        after = ["${container}.service" "network-online.target" "sops-install-secrets.service"];
        wants = ["network-online.target"];
        path = [r2Tool];

        serviceConfig = r2Backup.withScratchDirectory unit {
          Type = "oneshot";
          EnvironmentFile = [
            config.sops.templates.${envTemplate}.path
            config.sops.templates.${apiKeyTemplate}.path
          ];
          Environment = [
            "UNIFI_URL=https://${cfg.listenAddress}:${toString cfg.webPort}"
            "UNIFI_SITE=${site}"
            "UNIFI_STATISTICS_DAYS=${toString cfg.backup.statisticsDays}"
            "BACKUP_NAME=unifi"
            "BACKUP_AGE_RECIPIENT=${cfg.backup.ageRecipient}"
            "BACKUP_PREFIX=${cfg.backup.prefix}"
            "BACKUP_KEEP_DAYS=${toString cfg.backup.keepDays}"
          ];
          ExecStart = "${backupScript}/bin/unifi-backup-r2";
        };
      };

      systemd.timers.${unit} = {
        description = "Schedule the UniFi R2 backup";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = cfg.backup.schedule;
          Persistent = true;
          RandomizedDelaySec = "15m";
        };
      };
    }

    {
      systemd = r2Backup.verifyUnits {
        inherit lib pkgs;
        inherit (cfg) backup;
        environmentFile = config.sops.templates.${envTemplate}.path;
        name = "unifi";
        subject = "UniFi";
      };
    }
  ];
}
