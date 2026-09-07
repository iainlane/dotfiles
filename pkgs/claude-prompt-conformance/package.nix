# The prompt-conformance suite: the program, its fixtures and their tool
# environments. It drives the two agent clients pinned from `llm-agents`, and
# it uses enough of nixpkgs that it takes the package set rather than a list
# of individual dependencies; `args.nix` supplies all three.
#
# The program measures whichever prompt configuration its caller names on the
# command line. This wrapper supplies the suite's own half of that command
# line: the fixtures, the machinery, and the settings every prompt is measured
# with. The `ai` feature supplies the other half and exposes the result as
# `nix run .#claude-prompt-conformance`.
{
  claudeCode,
  codex,
  lib,
  pkgs,
}: let
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

  claudeEffort = "medium";
  claudeApiBudget = "0.75";
  # Public OAuth values from the pinned Claude client, retained with its version.
  claudeOauthTokenUrl = "https://platform.claude.com/v1/oauth/token";
  claudeOauthClientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
  codexJudgeEffort = "high";
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
    # contains, and no file is copied and hashed twice.
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
  # What `--list` must print. The `ai` feature compares it with the program's
  # own output, because the program lists its catalogue only once it has been
  # given a prompt configuration.
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
  makeResponseSchema = name:
    pkgs.runCommandLocal "prompt-conformance-${name}-schema.json" {
      nativeBuildInputs = [pythonApplication];
    } ''
      claude-prompt-conformance-schema ${lib.escapeShellArg name} > "$out"
    '';
  judgeSchema = makeResponseSchema "judgement";
  promptProposalSchema = makeResponseSchema "proposal";
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
  # Every isolated process is given this bundle: the sandbox cannot resolve the
  # host's own trust location, and the store is readable to all of them.
  tlsCertificateBundle = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
  suiteFlags = [
    "--fixtures"
    "${fixtureManifest}"
    "--isolation-backend"
    isolation.backend
    "--isolation-program"
    isolation.program
    "--git-program"
    (lib.getExe pkgs.gitMinimal)
    "--tls-certificate-bundle"
    tlsCertificateBundle
    "--claude-program"
    (lib.getExe claudeCode)
    "--claude-shell"
    (lib.getExe pkgs.bash)
    "--claude-version"
    claudeCode.version
    "--claude-effort"
    claudeEffort
    "--claude-api-budget"
    claudeApiBudget
    "--claude-oauth-token-url"
    claudeOauthTokenUrl
    "--claude-oauth-client-id"
    claudeOauthClientId
    "--codex-program"
    (lib.getExe codex)
    "--codex-version"
    codex.version
    "--mcp-program"
    "${pythonApplication}/bin/claude-prompt-conformance-mcp"
    "--judge-schema"
    "${judgeSchema}"
    "--proposal-schema"
    "${promptProposalSchema}"
    "--judge-effort"
    codexJudgeEffort
    "--improver-effort"
    codexImproverEffort
    "--codex-service-tier"
    codexServiceTier
    "--codex-verbosity"
    codexVerbosity
    "--codex-context-window"
    (toString codexContextWindow)
    "--codex-oauth-token-url"
    codexOauthTokenUrl
    "--codex-oauth-client-id"
    codexOauthClientId
    "--nix-program"
    (lib.getExe pkgs.nix)
    "--nixpkgs"
    "${pkgs.path}"
    "--variant-expression"
    "${variantExpressionSource}/variant.nix"
    "--variant-prompt-environment"
    "${variantExpressionSource}/prompt-environment.nix"
  ];

  # Sandboxed builds share the machine with whatever else is running, so
  # process-spawning tests can exceed the 30-second interactive timeout
  # pyproject.toml sets, without being hung. 120 seconds still catches a
  # genuine hang.
  sandboxedTestTimeout = "--timeout=120";

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
    pytestFlags = [
      "tests"
      sandboxedTestTimeout
    ];
    pythonImportsCheck = ["claude_prompt_conformance"];
  };

  runner = pkgs.symlinkJoin {
    name = "claude-prompt-conformance-${pythonApplication.version}";
    paths = [pythonApplication];
    nativeBuildInputs = [pkgs.makeWrapper];
    postBuild = ''
      wrapProgram "$out/bin/claude-prompt-conformance" \
        --add-flags ${lib.escapeShellArg (lib.escapeShellArgs suiteFlags)}
    '';
    meta.mainProgram = "claude-prompt-conformance";
  };

  codexProtocolCheck =
    pkgs.runCommandLocal "prompt-conformance-codex-protocol-check" {
      nativeBuildInputs = [
        codex
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
        ${sandboxedTestTimeout} \
        ${source}/tests/test_codex_app_server_contract.py
      touch "$out"
    '';

  codexEndpointCheck =
    pkgs.runCommandLocal "prompt-conformance-codex-endpoint-check" {
      nativeBuildInputs = [
        codex
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
        ${sandboxedTestTimeout} \
        ${source}/tests/test_codex_model_turn.py
      touch "$out"
    '';

  claudeEndpointCheck =
    pkgs.runCommandLocal "prompt-conformance-claude-endpoint-check" {
      nativeBuildInputs = [
        claudeCode
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
        ${sandboxedTestTimeout} \
        ${source}/tests/test_claude_model_turn.py
      touch "$out"
    '';

  # The fixture toolchains and the certificate bundle are used only during a
  # run, so nothing exercises them until a run needs them. This check runs the
  # Rust toolchain the starship fixture verifies with, and confirms the bundle
  # is where the wrapper says it is.
  fixtureEnvironmentCheck =
    pkgs.runCommandLocal "prompt-conformance-fixture-environment-check" {
      nativeBuildInputs = [pkgs.jq];
    } ''
      test -f ${tlsCertificateBundle}
      starshipPath=$(jq --raw-output \
        '.[] | select(.name == "starship-kotlin-gradle") | .environmentPath' \
        ${fixtureManifest})
      env PATH="$starshipPath" cargo clippy --version >/dev/null
      touch "$out"
    '';
in
  runner.overrideAttrs (old: {
    passthru =
      (old.passthru or {})
      // {
        # The prompt builder, so that a caller assembles the prompt it measures
        # exactly as a variant build rebuilds it.
        promptEnvironment = ./prompt-environment.nix;
        catalogue = expectedCatalogue;
        tests =
          (old.passthru.tests or {})
          // {
            claudeEndpoint = claudeEndpointCheck;
            codexEndpoint = codexEndpointCheck;
            codexProtocol = codexProtocolCheck;
            fixtureEnvironments = fixtureEnvironmentCheck;
            python = pythonApplication;
          };
      };
  })
