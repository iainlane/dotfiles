# The values that both AgentsView features use.
#
# Each machine keeps an archive of its agent sessions. Some machines push
# their archive to a shared database. One machine holds that database and
# shows a dashboard of it.
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

  # A work machine keeps its archive on the machine. It does not push.
  pushes = host: helpers.hasFeature host clientFeature && !helpers.hasFeature host workFeature;

  syncingHosts = hosts: lib.filterAttrs (_: pushes) hosts;

  # What each machine with the client feature does with its archive. The
  # machine that holds the database also pushes to it, and a machine that
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

  # Each machine connects as itself and has its own password. You can remove
  # the access of one machine and the others keep theirs.
  role = hostname: hostname;

  # The database's hostname and name, or null when no machine has the server
  # feature. `domain` is `flake.agentsviewServer.domain`; a server whose host
  # has not set it is an error here, so the clients do not conclude that
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

  # The certificate of a machine is beside its host record. The path comes
  # from the hostname, so the server finds each certificate itself. No list of
  # them is necessary.
  certificatePath = hostname: ../../hosts + "/${hostname}/agentsview.pem";

  hasCertificate = hostname: builtins.pathExists (certificatePath hostname);

  # A machine that pushes needs two secrets. Both paths come from the
  # hostname, so a machine does not state where its own secrets are.
  #
  # The first secret is the password of the database role. The server reads
  # the password of every machine and keeps the roles correct.
  #
  # The second secret is the private key of the certificate. It belongs to the
  # user that runs the push, so it sits with the other user secrets.
  #
  # A password goes into a connection URL. Make it with
  # `openssl rand -hex 32`. A password that contains `/`, `#`, `?` or `:`
  # reads as a port or a path, and the connection fails.
  passwordFile = hostname: "agentsview-postgres/${hostname}.yaml";
  passwordSecret = "password";

  # The secrets that belong to the user on one machine. The server reads the
  # password file above to make the roles, and it has no part in these.
  userSecretsFile = hostname: "${hostname}/user-agentsview.yaml";
  privateKeySecret = "agentsview_client_key";

  # AgentsView makes these two values at the first start and writes them into
  # its own configuration. The configuration here is read-only, thus they come
  # with it. Make each one with `openssl rand -base64 32`.
  #
  # The first value signs the cursors of the dashboard. The second one
  # authenticates a caller to the API of the dashboard.
  cursorSecret = "agentsview_cursor_secret";
  authTokenSecret = "agentsview_auth_token";

  # The name of a secret contains the machine that owns it. One host can hold
  # the secrets of several machines and keep them apart.
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
    privateKeySecret
    userSecretsFile
    pushes
    role
    serverSettings
    syncingHosts
    ;
}
