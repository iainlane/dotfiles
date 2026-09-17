{
  basedpyright,
  diffutils,
  gitMinimal,
  lib,
  makeWrapper,
  prose-lint-lexicon,
  python3Packages,
  ruff,
  runCommandLocal,
  stdenvNoCC,
  vale,
}: let
  version = "0.1.0";

  # The tests read the packaged style, configuration template and rule tiers
  # from the source tree, so they are part of the Python source as well.
  pythonSource = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./prose_lint
      ./pyproject.toml
      ./styles
      ./tests
      ./tiers.toml
      ./vale.ini.in
    ];
  };

  styleSource = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./styles
      ./tiers.toml
      ./vale.ini.in
    ];
  };

  fixtureSource = lib.fileset.toSource {
    root = ./.;
    fileset = ./fixtures;
  };

  goldens = ./scripts/goldens.bash;

  lexicon = "${prose-lint-lexicon}/share/prose-lint-lexicon/english.dict";

  application = python3Packages.buildPythonApplication {
    pname = "prose-lint-cli";
    inherit version;
    src = pythonSource;
    pyproject = true;

    build-system = [python3Packages.setuptools];
    dependencies = [python3Packages.tomli-w];

    nativeCheckInputs = [
      basedpyright
      gitMinimal
      python3Packages.pytest-timeout
      python3Packages.pytestCheckHook
      ruff
    ];

    preCheck = ''
      ruff check prose_lint tests
      ruff format --check prose_lint tests
      basedpyright prose_lint tests
    '';

    pytestFlags = ["tests"];
    pythonImportsCheck = ["prose_lint"];
  };

  prose-lint = stdenvNoCC.mkDerivation {
    pname = "prose-lint";
    inherit version;

    dontUnpack = true;
    dontBuild = true;

    nativeBuildInputs = [makeWrapper];

    installPhase = ''
      runHook preInstall

      share="$out/share/prose-lint"
      mkdir -p "$share"

      cp -r ${styleSource}/styles "$share/styles"
      chmod -R u+w "$share/styles"
      install -Dm644 ${styleSource}/tiers.toml "$share/tiers.toml"
      install -Dm755 ${goldens} "$share/goldens.bash"

      # Vale loads one dictionary per rule, so the house entries and the
      # general English core have to reach it in one file. A word with a house
      # entry is left out of the core, and the house entries are written
      # first.
      dictionaries="$share/styles/config/dictionaries"
      house="$dictionaries/House.dict"
      awk 'NR == FNR { house[$1]; next } !($1 in house)' \
        "$house" ${lexicon} |
        cat "$house" - >"$dictionaries/Lexicon.dict"

      # This file is also installed as the global Vale configuration under
      # ~/.config/vale, and Vale resolves a relative StylesPath against the
      # directory of the configuration file that it read. StylesPath is therefore
      # written as an absolute path into this output.
      substitute ${styleSource}/vale.ini.in "$share/vale.ini" \
        --replace-fail '@stylesPath@' "$share/styles"

      makeWrapper ${lib.getExe' application "prose-lint"} "$out/bin/prose-lint" \
        --set-default PROSE_LINT_SHARE "$share" \
        --prefix PATH : ${lib.makeBinPath [gitMinimal vale]}

      runHook postInstall
    '';

    meta = {
      description = "Vale style and linter for the Plain technical prose style";
      longDescription = ''
        prose-lint reads code comments, Markdown and commit messages and
        reports the constructions the Plain technical prose style rules out.
        It runs from the command line, as a git commit-msg hook, and as a
        Claude Code PreToolUse and PostToolUse hook.
      '';
      license = lib.licenses.mit;
      mainProgram = "prose-lint";
      platforms = lib.platforms.unix;
    };
  };

  fixtureCheck =
    runCommandLocal "prose-lint-fixture-check" {
      nativeBuildInputs = [diffutils vale];
    } ''
      cp -r ${fixtureSource}/fixtures fixtures
      chmod -R u+w fixtures

      bash ${prose-lint}/share/prose-lint/goldens.bash \
        ${prose-lint}/share/prose-lint \
        fixtures \
        --check

      touch "$out"
    '';

  configurationCheck =
    runCommandLocal "prose-lint-configuration-check" {
      nativeBuildInputs = [prose-lint vale];
    } ''
      export HOME="$PWD"
      share=${prose-lint}/share/prose-lint

      vale --no-global --config "$share/vale.ini" ls-config >/dev/null

      grep --fixed-strings --quiet "StylesPath = $share/styles" "$share/vale.ini"

      printf '%s\n\n%s\n' \
        'fix(db): index foo by quux' \
        'The query scanned the whole table on each request.' \
        >message.txt

      prose-lint commit-msg message.txt

      printf '%s\n\n%s\n' \
        'fix(db): index foo by quux' \
        'The query — which scanned the whole table — is now indexed.' \
        >dirty.txt

      if prose-lint commit-msg dirty.txt >findings.txt; then
        echo "a message with an em dash passed" >&2
        exit 1
      fi

      grep --fixed-strings --quiet 'Prose.EmDash' findings.txt

      printf '%s\n' \
        '# Every option this repository declares is listed, see `a -> b`.' \
        '{}' \
        >module.nix

      if prose-lint check module.nix >nix.txt; then
        echo "a zero-relative clause in a Nix comment passed" >&2
        exit 1
      fi

      grep --fixed-strings --quiet 'module.nix:1:' nix.txt
      grep --fixed-strings --quiet 'Prose.ZeroRelative' nix.txt

      if grep --fixed-strings --quiet 'Prose.ArrowChain' nix.txt; then
        echo "an arrow inside a code span was reported" >&2
        exit 1
      fi

      printf '%s\n' '-- A comment with nothing to report.' 'local x = 1' >clean.lua
      prose-lint check clean.lua

      if PROSE_LINT_SHARE=/nonexistent prose-lint check clean.lua; then
        echo "PROSE_LINT_SHARE from the environment was ignored" >&2
        exit 1
      fi

      touch "$out"
    '';
in
  prose-lint.overrideAttrs (old: {
    passthru =
      (old.passthru or {})
      // {
        inherit application;
        tests =
          (old.passthru.tests or {})
          // {
            configuration = configurationCheck;
            fixtures = fixtureCheck;
            python = application;
          };
      };
  })
