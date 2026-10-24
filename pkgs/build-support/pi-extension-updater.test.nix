{pkgs}: let
  inherit (pkgs) lib;
  npm = pkgs.writeShellApplication {
    name = "npm";
    text = ''
      case "$1" in
        view) printf '%s\n' "$PI_UPDATER_VERSION" ;;
        install)
          if [[ "''${PI_UPDATER_EXPECT_PATCH:-0}" == 1 ]]; then
            test "$(cat support.txt)" = after
            cp package.json "$PI_UPDATER_CONSUMED_MANIFEST"
          fi
          printf '%s\n' called >>"$PI_UPDATER_NPM_CALLS"
          cp "$PI_UPDATER_LOCK" package-lock.json
          ;;
        *) exit 1 ;;
      esac
    '';
  };
  wget = pkgs.writeShellApplication {
    name = "wget";
    text = ''
      test "$2" = -qO
      cp "$PI_UPDATER_ARCHIVE" "$3"
    '';
  };
  hash = pkgs.writeShellApplication {
    name = "nix";
    text = ''
      if [[ "''${PI_UPDATER_FAIL_HASH:-0}" == 1 ]]; then exit 1; fi
      printf '%s\n' 'sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
    '';
  };
  nix = pkgs.runCommand "pi-updater-nix-fixture" {} ''
    mkdir -p $out/bin
    ln -s ${lib.getExe hash} $out/bin/nix
    ln -s ${lib.getExe hash} $out/bin/nix-prefetch-url
  '';
  updaters = pkgs.callPackage ./updaters.nix {
    inherit nix wget;
    nodejs = npm;
  };
  manifestPatch = pkgs.writeText "pi-updater-manifest.patch" ''
    --- a/package.json
    +++ b/package.json
    @@ -1 +1 @@
    -{"name":"fixture","version":"2.0.0"}
    +{"name":"fixture","version":"2.0.0","peerDependencies":{"host":"^1.4.0"}}
    --- a/support.txt
    +++ b/support.txt
    @@ -1 +1 @@
    -before
    +after
  '';
  invalidPatch = pkgs.writeText "pi-updater-invalid.patch" ''
    --- a/support.txt
    +++ b/support.txt
    @@ -1 +1 @@
    -different
    +after
  '';
  make = gitHub: patches:
    updaters.mkPiExtensionUpdater {
      npmName = "fixture";
      pname = "fixture";
      inherit gitHub patches;
      npmDependencies = lib.optionalAttrs (patches != []) {runtime = "1.0.0";};
      metadataFiles."metadata.json" = "scripts/metadata.json";
    };
  gitHub = {
    owner = "fixture";
    repo = "fixture";
  };
  programs = map lib.getExe [
    (make null [])
    (make gitHub [])
    (make null [manifestPatch])
    (make gitHub [manifestPatch])
    (make null [invalidPatch])
    (make gitHub [invalidPatch])
  ];
in
  pkgs.runCommandLocal "pi-extension-updater-test" {
    nativeBuildInputs = [pkgs.bash pkgs.gitMinimal pkgs.gnutar pkgs.jq pkgs.diffutils];
  } ''
    bash ${./pi-extension-updater.test.bash} ${lib.escapeShellArgs programs}
    touch $out
  ''
