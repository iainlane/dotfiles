{
  hostConfig,
  lib,
  ...
}: {
  options.dotfiles.agentsviewServer.backup =
    ((import ../../../lib/r2-backup.nix).options {
      inherit lib;
      defaultPrefix = "agentsview";
      defaultSchedule = "*-*-* 02:00:00";
      defaultSecretsFile = "${hostConfig.name}/host-r2.yaml";
      defaultVerifySchedule = "*-*-* 06:00:00";
    })
    // {
      dumpRateLimit = lib.mkOption {
        type = lib.types.ints.positive;
        default = 10 * 1024 * 1024;
        description = ''
          Maximum dump output rate in bytes per second. Backpressure slows the
          dump without limiting the live database's other connections.
        '';
      };
    };
}
