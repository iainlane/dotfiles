# The prompt-conformance suite: it drives whole agent packages from
# `llm-agents` and reads this flake's own prompt files, so it takes the input
# set and the package set rather than a list of individual dependencies. The
# local package overlay passes both.
{
  inputs,
  lib,
  pkgs,
  stdenv,
}: let
  inherit (stdenv.hostPlatform) system;
  defaultModels = import ../../features/ai/models.nix;
  instructions = (import ../../features/ai/agent-instructions.nix {inherit lib;}).harnesses.claudeCode;
  managedSettings =
    (lib.evalModules {
      modules = [../../features/ai/claude-code/managed-settings-common.nix];
      specialArgs = {inherit defaultModels inputs pkgs;};
    }).config.dotfiles.claudeCode.managedSettings;
  # Dropped: the settings that would change the measured prompt, and the
  # settings that need host services the isolated candidate is denied.
  suiteManagedSettings = removeAttrs managedSettings [
    "enabledPlugins"
    "extraKnownMarketplaces"
    "fileSuggestion"
    "statusLine"
    "voiceEnabled"
  ];
  # The distribution and its tests, and nothing else, so that editing the
  # documentation or regenerating the demo recording leaves the pytest suite and
  # both endpoint checks cached.
  source = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./claude_prompt_conformance
      ./pyproject.toml
      ./tests
    ];
  };
  fixturesDirectory = ./fixtures;

  claudePackage = inputs.llm-agents.packages.${system}.claude-code;
  codexPackage = inputs.llm-agents.packages.${system}.codex;
  # The candidate is the model the managed settings select for daily use.
  claudeModel = suiteManagedSettings.model;
  claudeEffort = "medium";
  claudeApiBudget = "0.75";
  # Public OAuth values from the pinned Claude client, retained with its version.
  claudeOauthTokenUrl = "https://platform.claude.com/v1/oauth/token";
  claudeOauthClientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
  codexJudgeModel = "gpt-5.6-terra";
  codexJudgeEffort = "high";
  codexImproverModel = defaultModels.openai;
  codexImproverEffort = "high";
  codexServiceTier = "fast";
  codexVerbosity = "low";
  codexContextWindow = 272000;
  codexOauthTokenUrl = "https://auth.openai.com/oauth/token";
  codexOauthClientId = "app_EMoamEEZ73f0CkXaXp7hrann";

  makeEnvironmentPath = packages:
    lib.makeBinPath (
      [
        pkgs.bash
        pkgs.coreutils
        pkgs.gitMinimal
        pkgs.ripgrep
      ]
      ++ packages
    );
  starshipCc = pkgs.writeShellApplication {
    name = "cc";
    text = ''
      exec ${lib.getExe' pkgs.stdenv.cc "cc"} -L${pkgs.libiconv}/lib "$@"
    '';
  };
  # Preparation reads nothing but its workspace and /nix/store, so a lock file
  # kept beside the case reaches it only as a Nix path. The interpreter is named
  # by store path because uv otherwise prefers one of its own managed installs,
  # and the C toolchain builds the pinned dependencies which publish no wheel
  # for this platform.
  betterThermostatEnvironment = pkgs.writeShellApplication {
    name = "create-better-thermostat-environment";
    runtimeInputs = [pkgs.stdenv.cc pkgs.uv];
    text = ''
      uv venv \
        --no-python-downloads \
        --python ${lib.getExe' pkgs.python313 "python3.13"} \
        .venv

      exec uv pip install \
        --python .venv/bin/python \
        --no-python-downloads \
        --require-hashes \
        --requirement ${./fixtures/better-thermostat-pid-tests/requirements.lock}
    '';
  };
  environments = {
    dotfiles = makeEnvironmentPath [
      pkgs.gnugrep
      pkgs.gnutar
    ];
    cupboard = makeEnvironmentPath [
      pkgs.nodejs
      pkgs.pnpm
      pkgs.gnused
    ];
    wrapscallion = makeEnvironmentPath [
      pkgs.deno
    ];
    starship = makeEnvironmentPath [
      starshipCc
      pkgs.cargo
      pkgs.clippy
      pkgs.rustc
      pkgs.rustfmt
      pkgs.stdenv.cc
    ];
    llm-agents = makeEnvironmentPath [
      pkgs.jq
      pkgs.nix
      pkgs.nixfmt
    ];
    workflows = makeEnvironmentPath [
      pkgs.actionlint
    ];
    python = makeEnvironmentPath [
      betterThermostatEnvironment
      pkgs.python313
      pkgs.uv
    ];
    nix = makeEnvironmentPath [
      pkgs.alejandra
      pkgs.nix
    ];
    go = makeEnvironmentPath [
      pkgs.go
    ];
  };

  fixtureNames = builtins.attrNames (
    lib.filterAttrs (_: type: type == "directory")
    (builtins.readDir fixturesDirectory)
  );
  loadFixture = name: let
    directory = fixturesDirectory + "/${name}";
    case = builtins.fromJSON (builtins.readFile (directory + "/case.json"));
    environmentPath =
      environments.${case.environment}
      or (throw "fixture ${name} has an unknown environment");
    # A case declares its base revision once, under `repository`. A verification
    # argument or a reference subject that needs the same revision writes this
    # token, so the three cannot drift apart.
    resolveRevision = value:
      if value == "@baseRevision@"
      then case.repository.revision
      else value;
    verification =
      map (check: check // {command = map resolveRevision check.command;})
      case.verification;
    calibration = map (candidate:
      candidate
      // {
        repository =
          candidate.repository
          // {revision = resolveRevision candidate.repository.revision;};
        response = directory + "/${candidate.response}";
      })
    case.calibration;
    # The case, the task and the reference answers reach a run under names of
    # their own, so the fixture's source tree is whatever else the directory
    # contains, and no file is carried and hashed twice.
    declared =
      ["case.json" "task.txt"]
      ++ map (candidate: candidate.response) case.calibration;
    path = builtins.path {
      name = "prompt-conformance-fixture-${name}";
      path = directory;
      filter = file: _type: !(builtins.elem (baseNameOf file) declared);
    };
  in
    case
    // {
      inherit name path environmentPath calibration verification;
      comparisonRevision = case.comparisonRevision or case.repository.revision;
      task = directory + "/task.txt";
    };
  fixtures = map loadFixture fixtureNames;
  expectedCatalogue =
    pkgs.writeText "prompt-conformance-catalogue.json"
    (builtins.toJSON {
      event = "TestCatalogue";
      tests =
        map (fixture: {
          inherit (fixture) name description kind use category tags;
        })
        fixtures;
    });
  fixtureManifest =
    pkgs.writeText "prompt-conformance-fixtures.json"
    (builtins.toJSON fixtures);

  variantPatch = pkgs.writeText "prompt-conformance-variant-smoke.patch" ''
    --- a/output-style/plain-technical-prose.md
    +++ b/output-style/plain-technical-prose.md
    @@ -8,3 +8,3 @@

    -# Plain technical prose
    +# Plain technical prose test variant

  '';

  promptEnvironment = import ./prompt-environment.nix {
    inherit instructions lib pkgs;
    managedSettings = suiteManagedSettings;
  };
  promptSource = lib.fileset.toSource {
    root = ../../features/ai;
    fileset = lib.fileset.unions [
      ../../features/ai/agent-instructions.nix
      ../../features/ai/instructions
      ../../features/ai/output-style
      ../../features/ai/output-styles.nix
    ];
  };
  variantExpressionSource = pkgs.linkFarm "prompt-conformance-variant-expression" [
    {
      name = "variant.nix";
      path = ./variant.nix;
    }
    {
      name = "prompt-environment.nix";
      path = ./prompt-environment.nix;
    }
  ];
  inherit
    (promptEnvironment)
    candidateContext
    managedSettingsFile
    promptContext
    workspaceOverlay
    ;
  makeResponseSchema = name:
    pkgs.runCommandLocal "prompt-conformance-${name}-schema.json" {
      nativeBuildInputs = [pythonApplication];
    } ''
      claude-prompt-conformance-schema ${lib.escapeShellArg name} > "$out"
    '';
  judgeSchema = makeResponseSchema "judgement";
  promptProposalSchema = makeResponseSchema "proposal";
  runMetadataValue =
    {
      claude = {
        inherit (claudePackage) version;
        model = claudeModel;
        effort = claudeEffort;
      };
      codex = {
        inherit (codexPackage) version;
        judge = {
          model = codexJudgeModel;
          effort = codexJudgeEffort;
          serviceTier = codexServiceTier;
          verbosity = codexVerbosity;
          contextWindow = codexContextWindow;
        };
        improver = {
          model = codexImproverModel;
          effort = codexImproverEffort;
          serviceTier = codexServiceTier;
          verbosity = codexVerbosity;
          contextWindow = codexContextWindow;
        };
      };
    }
    // promptEnvironment.promptDigests;
  runMetadata =
    pkgs.writeText "prompt-conformance-run.json"
    (builtins.toJSON runMetadataValue);
  isolation =
    if pkgs.stdenv.hostPlatform.isDarwin
    then {
      backend = "darwin";
      program = "/usr/bin/sandbox-exec";
    }
    else {
      backend = "linux";
      program = lib.getExe pkgs.bubblewrap;
    };
  configurationValue = {
    inherit
      candidateContext
      fixtureManifest
      isolation
      promptContext
      runMetadata
      workspaceOverlay
      ;
    gitProgram = lib.getExe pkgs.gitMinimal;
    # Every isolated process is given this bundle: the sandbox cannot resolve
    # the host's own trust location, and the store is readable to all of them.
    tlsCertificateBundle = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    claude = {
      program = lib.getExe claudePackage;
      shell = lib.getExe pkgs.bash;
      settings = managedSettingsFile;
      model = claudeModel;
      effort = claudeEffort;
      apiBudgetUsd = claudeApiBudget;
      oauthTokenUrl = claudeOauthTokenUrl;
      oauthClientId = claudeOauthClientId;
      inherit (suiteManagedSettings) outputStyle;
    };
    codex = {
      program = lib.getExe codexPackage;
      mcpProgram = "${pythonApplication}/bin/claude-prompt-conformance-mcp";
      judge = {
        model = codexJudgeModel;
        effort = codexJudgeEffort;
        serviceTier = codexServiceTier;
        verbosity = codexVerbosity;
        contextWindow = codexContextWindow;
      };
      improver = {
        model = codexImproverModel;
        effort = codexImproverEffort;
        serviceTier = codexServiceTier;
        verbosity = codexVerbosity;
        contextWindow = codexContextWindow;
      };
      schema = judgeSchema;
      proposalSchema = promptProposalSchema;
      oauthTokenUrl = codexOauthTokenUrl;
      oauthClientId = codexOauthClientId;
    };
    variant = {
      nixProgram = lib.getExe pkgs.nix;
      nixpkgs = pkgs.path;
      expression = variantExpressionSource + "/variant.nix";
      promptEnvironment = variantExpressionSource + "/prompt-environment.nix";
      inherit promptSource;
    };
  };
  configuration =
    pkgs.writeText "prompt-conformance-configuration.json"
    (builtins.toJSON configurationValue);
  variantSmokeSource = pkgs.applyPatches {
    name = "prompt-conformance-variant-smoke-source";
    src = promptSource;
    patches = [variantPatch];
  };

  pythonApplication = pkgs.python3Packages.buildPythonApplication {
    pname = "prompt-conformance";
    inherit ((lib.importTOML ./pyproject.toml).project) version;
    src = source;
    pyproject = true;
    build-system = [pkgs.python3Packages.setuptools];
    dependencies =
      [
        pkgs.python3Packages.httpx
        pkgs.python3Packages.msgspec
        pkgs.python3Packages.mcp
        pkgs.python3Packages.psygnal
        pkgs.python3Packages.pydantic
        pkgs.python3Packages.rich
        pkgs.python3Packages.tomli-w
        pkgs.python3Packages.unidiff
        pkgs.python3Packages.watchfiles
      ]
      ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
        pkgs.python3Packages.pyobjc-framework-Security
      ];
    nativeCheckInputs = [
      pkgs.basedpyright
      pkgs.gitMinimal
      pkgs.python3Packages.pytestCheckHook
      pkgs.python3Packages.pytest-timeout
      pkgs.ruff
    ];
    preCheck = ''
      ruff check claude_prompt_conformance tests
      ruff format --check claude_prompt_conformance tests
      basedpyright claude_prompt_conformance tests
    '';
    disabledTestMarks = [
      "endpoint_integration"
      "host_integration"
    ];
    # Sandboxed builds share the machine with whatever else is running, so
    # process-spawning tests can exceed the 30-second interactive timeout
    # without being hung. 120 seconds still catches a genuine hang.
    pytestFlags = [
      "tests"
      "--timeout=120"
    ];
    pythonImportsCheck = ["claude_prompt_conformance"];
  };

  runner = pkgs.symlinkJoin {
    name = "claude-prompt-conformance-${pythonApplication.version}";
    paths = [pythonApplication];
    nativeBuildInputs = [pkgs.makeWrapper];
    postBuild = ''
      wrapProgram "$out/bin/claude-prompt-conformance" \
        --add-flags ${lib.escapeShellArg configuration}
    '';
    meta.mainProgram = "claude-prompt-conformance";
  };

  codexProtocolCheck =
    pkgs.runCommandLocal "prompt-conformance-codex-protocol-check" {
      nativeBuildInputs = [
        codexPackage
        pkgs.python3Packages.pytest
        pkgs.python3Packages.pytest-timeout
        pythonApplication
      ];
    } ''
      pytest \
        --config-file ${source}/pyproject.toml \
        --no-header \
        -p no:cacheprovider \
        --quiet \
        ${source}/tests/test_codex_app_server_contract.py
      touch "$out"
    '';

  codexEndpointCheck =
    pkgs.runCommandLocal "prompt-conformance-codex-endpoint-check" {
      nativeBuildInputs = [
        codexPackage
        pkgs.gitMinimal
        pkgs.python3Packages.pytest
        pkgs.python3Packages.pytest-timeout
        pythonApplication
      ];
      # The scripted model endpoint is a real listener the Codex child process
      # connects to, which the Darwin build sandbox permits only for loopback.
      __darwinAllowLocalNetworking = true;
    } ''
      pytest \
        --config-file ${source}/pyproject.toml \
        --no-header \
        -p no:cacheprovider \
        --quiet \
        ${source}/tests/test_codex_model_turn.py
      touch "$out"
    '';

  claudeEndpointCheck =
    pkgs.runCommandLocal "prompt-conformance-claude-endpoint-check" {
      nativeBuildInputs = [
        claudePackage
        pkgs.python3Packages.pytest
        pkgs.python3Packages.pytest-timeout
        pythonApplication
      ];
      # The scripted Messages endpoint is a real listener the Claude child
      # process connects to, which the Darwin build sandbox permits only for
      # loopback.
      __darwinAllowLocalNetworking = true;
    } ''
      pytest \
        --config-file ${source}/pyproject.toml \
        --no-header \
        -p no:cacheprovider \
        --quiet \
        ${source}/tests/test_claude_model_turn.py
      touch "$out"
    '';

  check =
    pkgs.runCommandLocal "prompt-conformance-check" {
      nativeBuildInputs = [runner pkgs.diffutils pkgs.gnugrep pkgs.jq];
    } ''
      claude-prompt-conformance --list >catalogue.json
      jq --compact-output --sort-keys . catalogue.json >catalogue.normalised.json
      jq --compact-output --sort-keys . ${expectedCatalogue} >expected.normalised.json
      cmp catalogue.normalised.json expected.normalised.json
      jq --exit-status \
        --slurpfile settings ${managedSettingsFile} \
        --arg judgeModel ${lib.escapeShellArg codexJudgeModel} \
        --arg improverModel ${lib.escapeShellArg defaultModels.openai} '
        .claude.model == $settings[0].model and
        .codex.judge == {"contextWindow":272000,"effort":"high","model":$judgeModel,"serviceTier":"fast","verbosity":"low"} and
        .codex.improver == {"contextWindow":272000,"effort":"high","model":$improverModel,"serviceTier":"fast","verbosity":"low"} and
        .tlsCertificateBundle == "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" and
        .codex.oauthTokenUrl == "${codexOauthTokenUrl}" and
        .codex.oauthClientId == "${codexOauthClientId}"
      ' ${configuration} >/dev/null
      test -f ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
      starshipPath=$(jq --raw-output '.[] | select(.name == "starship-kotlin-gradle") | .environmentPath' ${fixtureManifest})
      env PATH="$starshipPath" cargo clippy --version >/dev/null
      cmp \
        ${../../features/ai/instructions/claude-code/harness.md} \
        ${candidateContext}/rules/harness.md
      grep --fixed-strings --quiet \
        '# Plain technical prose test variant' \
        ${variantSmokeSource}/output-style/plain-technical-prose.md
      touch "$out"
    '';
in
  runner.overrideAttrs (old: {
    passthru =
      (old.passthru or {})
      // {
        tests =
          (old.passthru.tests or {})
          // {
            claudeEndpoint = claudeEndpointCheck;
            codexEndpoint = codexEndpointCheck;
            codexProtocol = codexProtocolCheck;
            conformance = check;
            python = pythonApplication;
          };
      };
  })
