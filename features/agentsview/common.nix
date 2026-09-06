# The values that both AgentsView features use.
#
# Each machine keeps an archive of its agent sessions. Some machines push
# their archive to a shared database. One machine runs that database and serves
# a dashboard of it.
#
# The two features must agree on three things: which machines push, where
# they push to, and which certificate each machine presents.
#
# Which machines push is read from the host records. Where they push to is
# `flake.agentsviewServer.domain`, which the host with the server feature
# sets beside its host record. To add a machine, give it the feature.
#
# `features` is `config.flake.features`. The predicates take the three
# features they test for from it, so a rename that misses one of them is an
# evaluation error here. With bare names, a missing feature would simply not
# match: a wrong client name stops every machine pushing, and a wrong work
# name makes the work machines push.
{
  features,
  lib,
}: let
  helpers = import ../../lib/features.nix {inherit lib;};

  clientFeature = features.agentsview;
  serverFeature = features."agentsview-server";
  workFeature = features.work;

  # A work machine keeps its archive locally and does not push.
  pushes = host: helpers.hasFeature host clientFeature && !helpers.hasFeature host workFeature;

  syncingHosts = hosts: lib.filterAttrs (_: pushes) hosts;

  # What each machine with the client feature does with its archive. The
  # machine that runs the database also pushes to it, and a machine that
  # keeps its sessions to itself still shows them on its own dashboard.
  #
  # Which secrets a machine needs follows from this. The `agentsviewHosts`
  # flake output exposes it to `generate-agentsview-secrets`.
  kinds = hosts:
    lib.mapAttrs (_: host:
      if helpers.hasFeature host serverFeature
      then "server"
      else if pushes host
      then "client"
      else "local")
    (lib.filterAttrs (_: host: helpers.hasFeature host clientFeature) hosts);

  # The database that stores the sessions. The server's option defaults to
  # it and the machines that push put it in their connection URL.
  database = "agentsview";

  # Each machine connects under its own role name with its own password, so one
  # machine's access can be revoked without touching the others.
  role = hostname: hostname;

  # The database's hostname and name, or null when no machine has the server
  # feature. `domain` is `flake.agentsviewServer.domain`; a server whose host
  # has not set it is an error here, so a client never silently concludes that
  # there is no server.
  serverSettings = {
    hosts,
    domain,
  }: let
    found = lib.attrNames (lib.filterAttrs (_: host: helpers.hasFeature host serverFeature) hosts);
  in
    if found == []
    then null
    else if domain == null
    then throw "Host '${lib.head found}' has the ${serverFeature.name} feature but does not set flake.agentsviewServer.domain"
    else {
      inherit domain database;
    };

  # The certificate of a machine is beside its host record. The path is derived
  # from the hostname, so the server finds each certificate itself and no list
  # of them is needed.
  certificatePath = hostname: ../../hosts + "/${hostname}/agentsview.pem";

  hasCertificate = hostname: builtins.pathExists (certificatePath hostname);

  # A machine that pushes needs two secrets. Both paths are derived from the
  # hostname, so a machine does not have to say where its own secrets are.
  #
  # The first is the password of its database role. The server reads every
  # machine's password and applies it to that machine's role.
  #
  # The second is the private key of its certificate. That key belongs to the
  # user who runs the push, so it is stored with the other user secrets.
  #
  # A password goes into a connection URL, so generate it with
  # `openssl rand -hex 32`. A password containing `/`, `#`, `?` or `:` reads as
  # a port or a path, and the connection fails.
  passwordFile = hostname: "agentsview-postgres/${hostname}.yaml";

  # The key inside that file, and the name the machine declares the sops
  # secret under. The two differ because the rendered secret lands in a
  # directory shared with every other feature's secrets, and a bare `password`
  # would collide with any other feature declaring one.
  passwordSecret = "password";
  passwordSecretName = "agentsview_password";

  # The secrets that belong to the user on one machine. The server reads the
  # password file above to create the roles; it never reads these.
  userSecretsFile = hostname: "${hostname}/user-agentsview.yaml";
  privateKeySecret = "agentsview_client_key";

  # AgentsView would generate these two values at first start and write them
  # into its own configuration, but the configuration here is read-only, so
  # both are supplied. Generate each with `openssl rand -base64 32`.
  #
  # `cursorSecret` signs the dashboard's cursors. `authTokenSecret`
  # authenticates a caller to the dashboard's API.
  cursorSecret = "agentsview_cursor_secret";
  authTokenSecret = "agentsview_auth_token";

  # A secret's name includes the machine it belongs to, so one host can store
  # several machines' passwords without them colliding.
  passwordSecretFor = hostname: "agentsview_password_${hostname}";
in {
  inherit
    authTokenSecret
    certificatePath
    cursorSecret
    database
    hasCertificate
    kinds
    passwordFile
    passwordSecret
    passwordSecretFor
    passwordSecretName
    privateKeySecret
    pushes
    role
    serverSettings
    syncingHosts
    userSecretsFile
    ;
}
