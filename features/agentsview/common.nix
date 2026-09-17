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
# `features` is `config.flake.features`. The predicates draw the three features
# from that set, so a rename that misses one of them is an
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
  hermesArchiveFeature = features.hermes.provides.agentsview;

  # A work machine keeps its archive locally and does not push.
  pushes = host: helpers.hasFeature host clientFeature && !helpers.hasFeature host workFeature;

  syncingHosts = hosts: lib.filterAttrs (_: pushes) hosts;

  # What each machine with the client feature does with its archive. The
  # machine that runs the database also pushes to it, and a machine that
  # keeps its sessions to itself still shows them on its own dashboard.
  #
  # The secrets for a machine follow from this. The `agentsviewHosts`
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

  # The key inside that file, and the name under which the machine declares
  # the sops secret. The two differ because the rendered secret lands in a
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

  # A secret's name includes its machine, so one host can store
  # several machines' passwords without them colliding.
  passwordSecretFor = hostname: "agentsview_password_${hostname}";

  mkPusher = {
    hostname,
    machine ? hostname,
    certificateName ? "agentsview",
    optional ? false,
  }: rec {
    inherit certificateName hostname machine optional;
    certificatePath = ../../hosts + "/${hostname}/${certificateName}.pem";
    hasCertificate = builtins.pathExists certificatePath;
    passwordFile = "agentsview-postgres/${machine}.yaml";
    passwordSecretName = "agentsview_password_${machine}";
  };

  pushers = hosts:
    lib.listToAttrs (
      map (hostname: lib.nameValuePair hostname (mkPusher {inherit hostname;}))
      (lib.attrNames (syncingHosts hosts))
      ++ map (hostname: let
        machine = "${hostname}-hermes";
      in
        lib.nameValuePair machine (mkPusher {
          inherit hostname machine;
          certificateName = "agentsview-hermes";
          optional = true;
        }))
      (lib.attrNames (lib.filterAttrs (_: host: helpers.hasFeature host hermesArchiveFeature) hosts))
    );

  dsn = {
    server,
    machine,
    password,
    certificate,
    key,
  }:
    "postgres://${machine}:${password}@${server.domain}:443/${server.database}"
    + "?sslmode=verify-full&sslnegotiation=direct&sslrootcert=system"
    + "&sslcert=${certificate}&sslkey=${key}";

  # The embedding provider that builds and queries the semantic-search index,
  # shared by every publisher that builds one and by the dashboard that
  # queries them. Model choice matches Hermes' LCM (`hosts/ancaster.nix`):
  # `baai/bge-m3` embeds at 1024 dimensions and is multilingual. The
  # fingerprint AgentsView stores a generation under comes from this model
  # name and dimension alone, not from which server answers to it, so a
  # publisher's build and the dashboard's queries can each use a different
  # server without forcing a new generation.
  embeddings = rec {
    model = "baai/bge-m3";
    dimension = 1024;

    # OpenRouter costs $0.01 per million input tokens and needs a key. A
    # local Ollama server is free and unauthenticated, but Ollama's library
    # drops the publisher namespace that OpenRouter's model identifiers use.
    backends = {
      openrouter = {
        serverName = "openrouter";
        endpoint = "https://openrouter.ai/api/v1";
        apiKeyEnvironment = "OPENROUTER_API_KEY";
      };
      local = {
        serverName = "local";
        endpoint = "http://localhost:11434/v1";
        apiKeyEnvironment = null;
        ollamaModel = lib.last (lib.splitString "/" model);
      };
    };

    # Hermes also declares a secret named `openrouter_api_key`, from its own
    # secrets file, so the sops secret name here has to differ even though
    # the key inside this feature's own file is the plain name.
    apiKeySecretName = "agentsview_embeddings_api_key";
    apiKeySecret = "openrouter_api_key";
    # Shared by every publisher that uses the OpenRouter backend and by the
    # dashboard, unlike the per-machine files above: they all embed against
    # the same provider and the same stored vectors, so one dedicated key
    # serves all of them.
    secretsFile = "agentsview-postgres/embeddings.yaml";
  };

  embeddingsFeature = features.agentsview.provides.embeddings;
  localEmbeddingsFeature = features.agentsview.provides.embeddings.provides.local;

  # Whether a host builds or queries the semantic-search index: the
  # `agentsview.embeddings` child feature. A host lists it explicitly;
  # `agentsview`'s own `includes` would pull it onto every host with
  # `agentsview`, and most of those hosts should not send their archive to
  # OpenRouter.
  hasEmbeddings = hostConfig: helpers.hasFeature hostConfig embeddingsFeature;

  # Whether that index builds against a local Ollama server: the
  # `agentsview.embeddings.local` child feature.
  hasLocalEmbeddings = hostConfig: helpers.hasFeature hostConfig localEmbeddingsFeature;

  # The `[vector]` block of `config.toml`, naming the given backend. A
  # publisher building the index and the dashboard querying it both need
  # this: AgentsView reads the model and dimension to interpret stored
  # vectors, and reads the server to embed new text, whether that text is a
  # session message or a search query.
  vectorConfig = backend: let
    inherit (embeddings.backends.${backend}) serverName endpoint apiKeyEnvironment;
  in
    ''

      [vector]
      enabled = true

      [vector.embeddings]
      model = "${embeddings.model}"
      dimension = ${toString embeddings.dimension}

      [vector.embeddings.servers.${serverName}]
      endpoint = "${endpoint}"
    ''
    + lib.optionalString (apiKeyEnvironment != null) ''
      api_key_env = "${apiKeyEnvironment}"
    '';
in {
  inherit
    authTokenSecret
    certificatePath
    cursorSecret
    database
    dsn
    embeddings
    hasCertificate
    hasEmbeddings
    hasLocalEmbeddings
    kinds
    passwordFile
    passwordSecret
    passwordSecretFor
    passwordSecretName
    privateKeySecret
    pushes
    pushers
    role
    serverSettings
    syncingHosts
    userSecretsFile
    vectorConfig
    ;
}
