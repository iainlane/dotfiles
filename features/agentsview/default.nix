# AgentsView, as two features that are two halves of one concern.
#
# `agentsview` runs on a machine with coding agents: it archives their session
# files and either shows a local dashboard or pushes to the shared database.
# `agentsview-server` runs the database and the shared dashboard. The two have
# to agree on the role names, the secrets and the server's address, which
# `common.nix` defines, so they are registered together.
{
  config,
  inputs,
  lib,
  ...
}: let
  common = import ./common.nix {inherit lib;};
in {
  options.flake = {
    agentsviewServer.domain = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "pg.example.com";
      description = ''
        The hostname of the shared session database. The host with the
        `agentsview-server` feature sets this beside its host record. The
        server listens on it, and every pushing machine connects to it, so it
        is declared once at the flake level instead of being read out of the
        server's configuration.
      '';
    };

    agentsviewHosts = lib.mkOption {
      type = lib.types.attrsOf (lib.types.enum ["server" "client" "local"]);
      description = ''
        What each machine with the AgentsView feature does with its archive.
        `just generate-agentsview-secrets` reads this to decide which secrets
        each machine needs.
      '';
    };
  };

  config.flake = {
    agentsviewHosts = common.kinds config.flake.hosts;

    features = {
      agentsview = import ./client.nix {inherit config inputs lib;};
      agentsview-server = import ./server.nix {inherit config inputs lib;};
    };
  };
}
