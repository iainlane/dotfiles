{lib}: let
  database = "agentsview";
  roles = {
    superuser = "postgres";
    group = "agentsview_push";
    dashboard = "agentsview_dashboard";
  };
  domainType = lib.types.addCheck lib.types.nonEmptyStr (value:
    lib.stringLength value
    <= 253
    && lib.all (label: builtins.match "[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?" label != null) (lib.splitString "." value));
  machineType = lib.types.addCheck (lib.types.strMatching "[A-Za-z0-9._-]{1,63}") (value:
    !lib.hasPrefix "pg_" value
    && !lib.elem value (["." ".." "public" "none"] ++ lib.attrValues roles));
  relativePath = lib.types.addCheck lib.types.nonEmptyStr (value:
    !lib.hasPrefix "/" value
    && !lib.hasPrefix "-" value
    && !lib.hasInfix "\\" value
    && lib.all (segment: !lib.elem segment ["" "." ".."]) (lib.splitString "/" value)
    && builtins.match "[^\n\r\t]+" value != null);
  passwordSecret = "password";
  privateKeySecret = "agentsview_client_key";
  cursorSecret = "agentsview_cursor_secret";
  authTokenSecret = "agentsview_auth_token";
  publisher = inputs: identity: let
    sourcePath = inputs.self + "/${identity.certificate}";
  in
    identity
    // {
      certificatePath = builtins.path {
        path = sourcePath;
        name = lib.strings.sanitizeDerivationName (baseNameOf identity.certificate);
      };
      hasCertificate = builtins.pathExists sourcePath;
      passwordSecretName = "agentsview_password_${identity.machine}";
    };
  dsn = {
    server,
    machine,
    password,
    certificate,
    key,
  }:
    "postgres://${machine}:${password}@${server.domain}:443/${server.database}"
    + "?sslmode=verify-full&sslnegotiation=direct&sslrootcert=system"
    + "&sslcert=${lib.escapeURL certificate}&sslkey=${lib.escapeURL key}";
  # The embedding provider that builds and queries the semantic-search index,
  # shared by every publisher that builds one and by the dashboard that
  # queries them. Model choice matches Hermes' LCM (`hosts/ancaster.nix`):
  # `baai/bge-m3` embeds at 1024 dimensions and is multilingual. The
  # fingerprint AgentsView stores a generation under comes from this model
  # name and dimension alone, not from which server answers to it, so a
  # publisher's build and the dashboard's queries can each use a different
  # server without forcing a new generation.
  embeddings = let
    models.bge-m3 = {
      name = "baai/bge-m3";
      # Ollama's library drops the publisher namespace that OpenRouter's
      # model identifiers use.
      ollamaName = "bge-m3";
      dimension = 1024;
      contextTokens = 8192;
    };
  in {
    inherit models;
    defaultModel = models.bge-m3;

    # OpenRouter costs $0.01 per million input tokens and needs a key. A
    # local Ollama server is free and unauthenticated.
    backends = {
      openrouter = {
        serverName = "openrouter";
        endpoint = "https://openrouter.ai/api/v1";
        apiKeyEnvironment = "OPENROUTER_API_KEY";
        timeout = "30s";
        batchSize = null;
        concurrency = null;
      };
      local = {
        serverName = "local";
        endpoint = "http://localhost:11434/v1";
        apiKeyEnvironment = null;
        # The embedding model is not always resident in Ollama's GPU
        # memory. A cold-start load can take 20–35 seconds for this
        # 1.2 GB model. The default 30 s is at the edge of that range,
        # so a search can time out before the model finishes loading.
        timeout = "120s";
        # Ollama embeds one input at a time, so concurrent requests queue
        # and the last ones reach the timeout before Ollama starts them.
        # Eight inputs at the model's full context length take about a
        # minute on Bonington's integrated GPU.
        batchSize = 8;
        concurrency = 1;
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

  # Serialises a nested attrset as a TOML document. Nested attrsets become
  # TOML sections; at each level, scalar keys come before section headers,
  # separated by a blank line.
  toTOML = let
    tomlString = s: let
      escaped =
        builtins.replaceStrings
        [
          "\\"
          "\""
          "\n"
          "\r"
          "\t"
          (builtins.fromJSON ''"\u0008"'')
          (builtins.fromJSON ''"\u000C"'')
        ]
        [
          "\\\\"
          "\\\""
          "\\n"
          "\\r"
          "\\t"
          "\\b"
          "\\f"
        ]
        s;
    in ''"${escaped}"'';
    value = v:
      if builtins.isBool v
      then
        (
          if v
          then "true"
          else "false"
        )
      else if builtins.isInt v
      then toString v
      else if builtins.isFloat v
      then builtins.toJSON v
      else if builtins.isString v
      then tomlString v
      else if builtins.isList v
      then "[${lib.concatMapStringsSep ", " value v}]"
      else throw "toTOML: cannot serialise ${builtins.typeOf v}";
    lines = prefix: attrs: let
      scalars = lib.filterAttrs (_: v: !builtins.isAttrs v) attrs;
      sections = lib.filterAttrs (_: builtins.isAttrs) attrs;
      scalarLines = lib.mapAttrsToList (k: v: "${k} = ${value v}") scalars;
      sectionLines = lib.concatMap (k: let
        full =
          if prefix == ""
          then k
          else "${prefix}.${k}";
      in
        ["" "[${full}]"] ++ lines full sections.${k}) (builtins.attrNames sections);
    in
      scalarLines ++ sectionLines;
  in
    attrs: lib.concatStringsSep "\n" (lines "" attrs);

  # A publisher building the index and the dashboard querying it both need this:
  # AgentsView reads the model and dimension to interpret stored vectors, and
  # reads the server to embed new text, whether that text is a session message
  # or a search query.
  vectorConfig = backend: let
    inherit (embeddings.backends.${backend}) serverName endpoint apiKeyEnvironment timeout batchSize concurrency;
    serverAttrs =
      {inherit endpoint timeout;}
      // lib.optionalAttrs (apiKeyEnvironment != null) {api_key_env = apiKeyEnvironment;}
      // lib.optionalAttrs (batchSize != null) {batch_size = batchSize;}
      // lib.optionalAttrs (concurrency != null) {inherit concurrency;};
  in {
    vector =
      {
        enabled = true;
        embeddings = {
          model = embeddings.defaultModel.name;
          inherit (embeddings.defaultModel) dimension;
          servers.${serverName} = serverAttrs;
        };
      }
      // lib.optionalAttrs (backend == "local") {
        # The Linux embedding service waits for the model loader to download the
        # model and create its alias. It also checks GPU use when acceleration
        # is required. AgentsView's after-sync and periodic builds run inside
        # the daemon, bypassing those service prerequisites. Keep both triggers
        # disabled so automatic local builds run through the managed timer.
        embed = {
          run_after_sync = false;
          backstop_interval = "-1s";
        };
      };
  };
in {
  inherit authTokenSecret cursorSecret database domainType dsn embeddings machineType passwordSecret privateKeySecret publisher relativePath roles toTOML vectorConfig;
}
