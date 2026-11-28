{pkgs}: let
  inherit (pkgs) lib;
  command = pkgs.writeShellApplication {
    name = "nix-update";
    text = ''
      printf '%s\n' "$@" >"$UPDATER_ARGS"
      printf '%s\n' "$NIX_PATH" >"$UPDATER_NIX_PATH"
    '';
  };
  nix-update = pkgs.callPackage ./nix-update.nix {
    nix-update = command // {
      version = "1.16.0";
      overridePythonAttrs = override:
        assert (override {}).version == "1.17.0";
          command;
    };
    nixpkgsPath = "/fixture/nixpkgs";
  };
  updaters = pkgs.callPackage ./updaters.nix {inherit nix-update;};
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
    export UPDATER_ARGS="$TMPDIR/arguments" UPDATER_NIX_PATH="$TMPDIR/nix-path"
    mkdir repository
    cd repository
    git init -q

    env -u NIX_PATH ${lib.getExe refreshable}
    printf '%s\n' --flake --override-filename pkgs/fixture/package.nix --version=branch=integration ${attribute} >expected
    diff -u expected "$UPDATER_ARGS"
    grep -Fx 'nixpkgs=/fixture/nixpkgs' "$UPDATER_NIX_PATH"

    NIX_PATH=nixpkgs=/other/nixpkgs:extra=/other/input ${lib.getExe refreshable} --refresh
    printf '%s\n' --flake --override-filename pkgs/fixture/package.nix --version=skip --no-src ${attribute} >expected
    diff -u expected "$UPDATER_ARGS"
    grep -Fx 'nixpkgs=/fixture/nixpkgs:nixpkgs=/other/nixpkgs:extra=/other/input' "$UPDATER_NIX_PATH"

    rm "$UPDATER_ARGS"
    if ${lib.getExe sourceOnly} --refresh >message; then
      echo 'The source-only updater accepted --refresh.' >&2
      exit 1
    fi
    test ! -e "$UPDATER_ARGS"
    grep -Fx 'Unsupported updater arguments.' message
    touch "$out"
  ''
