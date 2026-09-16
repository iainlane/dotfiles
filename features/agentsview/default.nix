# Registers the two AgentsView features and declares the flake options they
# share.
#
# `agentsview` runs on a machine with coding agents: it archives their session
# files and either shows a local dashboard or pushes to the shared database.
# `agentsview-server` runs the database and the shared dashboard. The two have
# to agree on the role names, the secrets and the server's address, so they
# are registered together: `common.nix` defines the role and secret helpers,
# and the address is the `flake.agentsviewServer.domain` option declared
# below, which the server's host sets.
{
  config,
  inputs,
  lib,
  ...
}: let
  common = import ./common.nix {
    inherit lib;
    inherit (config.flake) features;
  };
in {
  imports = [./embeddings ./server-backup];

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

    agentsviewPushers = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          host = lib.mkOption {type = lib.types.str;};
          machine = lib.mkOption {type = lib.types.str;};
          certificate = lib.mkOption {type = lib.types.str;};
          passwordFile = lib.mkOption {type = lib.types.str;};
          secretsFile = lib.mkOption {type = lib.types.str;};
          recipientSource = lib.mkOption {type = lib.types.nullOr lib.types.str;};
          serverRecipientSource = lib.mkOption {type = lib.types.str;};
        };
      });
      description = ''
        The archive identities that push to the shared database. The secrets
        generator reads these records so it uses the same machine names and
        paths as the evaluated host configurations.
      '';
    };
  };

  config.flake = {
    agentsviewHosts = common.kinds config.flake.hosts;
    agentsviewPushers = let
      serverHosts = lib.attrNames (lib.filterAttrs (_: kind: kind == "server") config.flake.agentsviewHosts);
      serverHost =
        if serverHosts == []
        then throw "AgentsView has archive pushers but no host has the agentsview-server feature"
        else lib.head serverHosts;
      serverSecretsFile = config.flake.systemConfigs.${serverHost}.passthru.config.dotfiles.agentsviewServer.secretsFile;
    in
      lib.mapAttrs (_: pusher: {
        host = pusher.hostname;
        inherit (pusher) machine passwordFile;
        certificate = "hosts/${pusher.hostname}/${pusher.certificateName}.pem";
        secretsFile =
          if pusher.optional
          then config.flake.systemConfigs.${pusher.hostname}.passthru.config.dotfiles.hermes.agentsview.secretsFile
          else common.userSecretsFile pusher.hostname;
        recipientSource =
          if pusher.optional
          then config.flake.systemConfigs.${pusher.hostname}.passthru.config.dotfiles.hermes.agentsview.secretsFile
          else null;
        serverRecipientSource = serverSecretsFile;
      }) (common.pushers config.flake.hosts);

    features = {
      agentsview = import ./client.nix {inherit config inputs lib;};
      agentsview-server = import ./server.nix {inherit config inputs lib;};
    };
  };
}
