{
  basedpyright,
  diffutils,
  fetchurl,
  gitMinimal,
  lib,
  makeWrapper,
  prose-lint-lexicon,
  python3Packages,
  ruff,
  runCommandLocal,
  stdenvNoCC,
  unzip,
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

  # Since Vale 3.27 the comment parsers ship as separate WebAssembly modules.
  grammars = lib.mapAttrsToList (name: hash:
    fetchurl {
      url = "https://github.com/vale-cli/vale/releases/download/v3.27.0/grammar-${name}.zip";
      sha256 = hash;
    }) {
    bash = "383f41dac7ba7ff6b62310ae90fbecad5872b421e16362428e85f6d3383282a4";
    c = "0e4d8e14893f8f20dccf7ee85c79c6beeeac4c77f032551a237067a93b450b0d";
    cpp = "0f550858aa68c02663362631dc64d40e7b1a28aa48379fa5d55c0dfc3bf905f7";
    csharp = "1c5ef2dc517dcd7fad2c7e6d1e2b5c8a60690b10d34a22cb3b108d98b3b73898";
    css = "efc982ba928828df69d3a0a8d17ff4095b5890d9f918c41ce34adff940d31529";
    elixir = "3beddaad99e1f3069948d5233709feb1ce8aaeab5b5a8333de3dc5e32659ecb0";
    elm = "baedd9bdc51c76883a7d5f81e340e210f117e4355bc2fd479ae4b11ce8041ff1";
    go = "c188c53747864bff9849cc39eaac51393c3264be8ae3c67c12edb2ccc94eb130";
    java = "fc65e8426fe7116ef941b227520beb542cd2f6c8cf0789d28b63b370e8d36827";
    javascript = "448d9a94d558b4e2e62c929b815378337ea5a151fc12e1f8277c853314c9e1d4";
    julia = "edc4dbc9cfb3dc06f72c1820a7bd16d481a4c492efa35f9dd7a23a7c876d29f8";
    kotlin = "58b5e2d01f1920cb2fb908863a477b6cd14cc0e3cf8a36fc4413191b709f4926";
    lua = "10c94b27ea4d6cf4779be2bcf57accf256b1c752b57fcf27ff56be297ad9178f";
    php = "326f84f19873498972a9b606b4af4c5e4cfa77a75a45bb1ac6c29801bf9c16f2";
    proto = "4262870472d181b4bbc6afb3df39d81de13f84910d6f87a4032d66d346c17bef";
    python = "cd369ca78cb327534bfab0eefb710b38115e0644cda04709da174f675c28a1b2";
    ruby = "a31c8e1f88bab718794f281cbf6b7b4c5cfaf3526e379da1ba53ca7d3cfe6548";
    rust = "040788500c7414b3e789f08f0281e4d12fdcf197720beb238e27139bde511631";
    toml = "8a66d9450aba2f7d1423d16ed6bdc84a2d14dbb6eb26cd75a476128d5bdd2912";
    tsx = "b051dedfe0ad634a6689c7d328f5df61b2a44fe120cf93146c2d4185fb43f5bc";
    typescript = "d127e82362d35ec0d8945049b9f51735e0db10091b7d884f47ce2f6aebe7a162";
    yaml = "8184a6cf2329f6cbc6748fbf8807ae5b58de7ab20f9a19f1301efd1c36a4b971";
  };

  application = python3Packages.buildPythonApplication {
    pname = "prose-lint-cli";
    inherit version;
    src = pythonSource;
    pyproject = true;

    build-system = [python3Packages.setuptools];
    dependencies = [
      python3Packages.pathspec
      python3Packages.pygments
      python3Packages.tomli-w
    ];

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

    nativeBuildInputs = [makeWrapper unzip];

    installPhase = ''
      runHook preInstall

      share="$out/share/prose-lint"
      mkdir -p "$share"

      cp -r ${styleSource}/styles "$share/styles"
      chmod -R u+w "$share/styles"
      mkdir -p "$share/styles/config/grammars"
      for grammar in ${lib.escapeShellArgs grammars}; do
        unzip -j "$grammar" '*/styles/config/grammars/*.wasm' -d "$share/styles/config/grammars"
      done
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

      mkdir -p "$share/pi"
      substitute ${./pi/index.ts} "$share/pi/index.ts" \
        --replace-fail '@proseLint@' "$out/bin/prose-lint"

      runHook postInstall
    '';

    meta = {
      description = "Vale style and linter for the Plain technical prose style";
      longDescription = ''
        prose-lint reads code comments, Markdown and commit messages and
        reports the constructions the Plain technical prose style rules out.
        It runs from the command line, as a git commit-msg hook, as Claude
        Code and Codex hooks, and as a pi extension.
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

      # A commit message is read as Markdown, so a code span is skipped, and
      # the commit rules still see its trailers.
      printf '%s\n\n%s\n%s\n\n%s\n' \
        'fix(ui): read the colour setting' \
        'The `ui.color` setting was ignored.' \
        'The color is now read at start-up.' \
        'Co-Authored-By: Someone <someone@example.com>' \
        >trailer.txt

      if prose-lint commit-msg trailer.txt >trailer-findings.txt; then
        echo "a message with a Co-Authored-By trailer passed" >&2
        exit 1
      fi

      grep --fixed-strings --quiet 'Prose.Trailers' trailer-findings.txt
      # Line 4 has the same word outside a code span. Its finding shows that
      # the spelling rule ran, so the absence of one on line 3 means something.
      grep --fixed-strings --quiet 'trailer.txt:4:' trailer-findings.txt

      if grep --quiet 'trailer.txt:3:.*Prose.BritishSpelling' trailer-findings.txt; then
        echo "a word inside a code span in a commit message was reported" >&2
        cat trailer-findings.txt >&2
        exit 1
      fi

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

      printf '%s\n' '# Every option this repository declares is listed.' >dirty.zsh
      if prose-lint check dirty.zsh >zsh.txt; then
        echo "an object-relative clause in a Zsh comment passed" >&2
        exit 1
      fi
      grep --fixed-strings --quiet 'dirty.zsh:1:' zsh.txt
      grep --fixed-strings --quiet 'Prose.ZeroRelative' zsh.txt

      printf '%s\n' \
        '# The colour setting comes from LS_COLORS.' \
        'print -r -- "A string — which is code."' \
        >clean.zsh
      prose-lint check clean.zsh

      printf '%s\n' '-- A comment with nothing to report.' 'local x = 1' >clean.lua
      prose-lint check clean.lua

      printf '%s\n' \
        '<?php' \
        '// The image uses local assets.' \
        '$value = "A string — which is code.";' \
        >clean.php
      prose-lint check clean.php

      printf '%s\n' '<?php' '// The image — with local assets — starts.' \
        '// Every option this repository declares is listed.' >dirty.php
      if prose-lint check dirty.php >php.txt; then
        echo "an em dash in a PHP comment passed" >&2
        exit 1
      fi

      grep --fixed-strings --quiet 'dirty.php:2:' php.txt
      grep --fixed-strings --quiet 'Prose.EmDash' php.txt
      grep --fixed-strings --quiet 'Prose.ZeroRelative' php.txt

      # Identifier-shaped tokens are not prose: a header name such as
      # `X-Color-Mode`, a dotted name such as `ui.color`, and a long option
      # such as `--color`. Only the sentence on the last comment line is prose
      # to report.
      printf '%s\n' \
        '// X-Color-Mode: dark' \
        '//' \
        '//! The ui.color setting and the --color flag set the Content-Color header.' \
        '//! The color is wrong.' \
        'fn main() {}' \
        >identifiers.rs
      printf '%s\n' \
        '# X-Color-Mode: dark' \
        '#' \
        '# The ui.color setting and the --color flag set the Content-Color header.' \
        '# The color is wrong.' \
        '{}' \
        >identifiers.nix

      prose-lint check identifiers.rs identifiers.nix >identifiers.txt || true

      for file in identifiers.rs identifiers.nix; do
        grep --fixed-strings --quiet "$file:4:" identifiers.txt

        if grep --quiet "^$file:[123]:" identifiers.txt; then
          echo "an identifier in $file was reported" >&2
          cat identifiers.txt >&2
          exit 1
        fi
      done

      # A determiner and the noun after it can be on different lines of a
      # wrapped comment. The noun is still reported; the verb is not.
      printf '%s\n' \
        '// Read the' \
        '// license before you start.' \
        '// You may license the code.' \
        'fn main() {}' \
        >licence.rs

      prose-lint check licence.rs >licence.txt || true

      grep --quiet '^licence.rs:2:.*Prose.BritishSpelling' licence.txt

      if grep --quiet '^licence.rs:3:' licence.txt; then
        echo "the verb license was reported" >&2
        cat licence.txt >&2
        exit 1
      fi

      if PROSE_LINT_SHARE=/nonexistent prose-lint check clean.lua; then
        echo "PROSE_LINT_SHARE from the environment was ignored" >&2
        exit 1
      fi

      mkdir -p scoped/docs/generated
      cd scoped
      printf '%s\n' 'Documentation permits em dashes.' >style.md
      printf '%s\n' 'An option — with prose.' >docs/page.md
      printf '%s\n' '# An option — with prose.' >docs/module.nix
      cp docs/page.md docs/generated/page.md
      cp docs/page.md README.md

      prose-lint allow EmDash --level NO \
        --file 'docs/**' --file '!docs/generated/**' --because style.md

      prose-lint check docs/page.md docs/module.nix

      if prose-lint check docs/generated/page.md README.md >remaining.txt; then
        echo "files outside the override's scope passed" >&2
        exit 1
      fi

      grep --fixed-strings --quiet 'docs/generated/page.md:1:' remaining.txt
      grep --fixed-strings --quiet 'README.md:1:' remaining.txt

      if prose-lint commit-msg docs/page.md >commit.txt; then
        echo "a commit message used a file-scoped override" >&2
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
        updateScript = null;
        maintenance.source = "repository";
        tests =
          (old.passthru.tests or {})
          // {
            configuration = configurationCheck;
            fixtures = fixtureCheck;
            python = application;
          };
      };
  })
