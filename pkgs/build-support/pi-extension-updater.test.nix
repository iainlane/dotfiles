{pkgs}: let
  inherit (pkgs) lib;
  npm = pkgs.writeShellApplication {
    name = "npm";
    text = ''
      case "$1" in
        view) printf '%s\n' "$PI_UPDATER_VERSION" ;;
        install) cp "$PI_UPDATER_LOCK" package-lock.json ;;
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
  make = gitHub:
    updaters.mkPiExtensionUpdater {
      npmName = "fixture";
      pname = "fixture";
      inherit gitHub;
      metadataFiles."metadata.json" = "scripts/metadata.json";
    };
in
  pkgs.runCommandLocal "pi-extension-updater-test" {
    nativeBuildInputs = [pkgs.bash pkgs.gitMinimal pkgs.gnutar pkgs.jq pkgs.diffutils];
  } ''
    bash ${./pi-extension-updater.test.bash} ${lib.getExe (make null)} ${lib.getExe (make {
      owner = "fixture";
      repo = "fixture";
    })}
    touch $out
  ''
