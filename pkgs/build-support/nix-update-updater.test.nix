{pkgs}: let
  inherit (pkgs) lib;
  command = pkgs.writeShellApplication {
    name = "nix-update";
    text = ''printf '%s\n' "$@" >"$UPDATER_ARGS"'';
  };
  updaters = pkgs.callPackage ./updaters.nix {nix-update = command;};
  attribute = "legacyPackages.${pkgs.stdenv.hostPlatform.system}.localPackages.fixture";
  make = refresh:
    updaters.mkNixUpdateUpdater {
      attr = "fixture";
      inherit refresh;
      extraFlags = ["--version=branch=integration"];
    };
  refreshable = make true;
  sourceOnly = make false;
in
  pkgs.runCommandLocal "nix-update-updater-test" {
    nativeBuildInputs = [pkgs.git pkgs.diffutils];
  } ''
    export UPDATER_ARGS="$TMPDIR/arguments"
    mkdir repository
    cd repository
    git init -q

    ${lib.getExe refreshable}
    printf '%s\n' --flake --override-filename pkgs/fixture/package.nix --version=branch=integration ${attribute} >expected
    diff -u expected "$UPDATER_ARGS"

    ${lib.getExe refreshable} --refresh
    printf '%s\n' --flake --override-filename pkgs/fixture/package.nix --version=skip --no-src ${attribute} >expected
    diff -u expected "$UPDATER_ARGS"

    rm "$UPDATER_ARGS"
    if ${lib.getExe sourceOnly} --refresh >message; then
      echo 'The source-only updater accepted --refresh.' >&2
      exit 1
    fi
    test ! -e "$UPDATER_ARGS"
    grep -Fx 'Unsupported updater arguments.' message
    touch "$out"
  ''
