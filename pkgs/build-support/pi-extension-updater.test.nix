{pkgs}: let
  inherit (pkgs) lib;
  npm = pkgs.writeShellApplication {
    name = "npm";
    text = ''
      # npm reads `registry` from the environment first, then from the
      # project, user and global configuration files. A scope's registry
      # setting overrides `registry` for packages in that scope.
      config_value() {
        local key="$1" file value

        if [[ "$key" == registry && -n "''${npm_config_registry:-}" ]]; then
          printf '%s\n' "$npm_config_registry"
          return
        fi

        for file in .npmrc "''${npm_config_userconfig:-$HOME/.npmrc}" "''${npm_config_globalconfig:-''${PI_UPDATER_GLOBAL_NPMRC:-}}"; do
          if [[ ! -f "$file" ]]; then
            continue
          fi

          value="$(sed -n "s|^$key=||p" "$file")"
          if [[ -n "$value" ]]; then
            printf '%s\n' "$value"
            return
          fi
        done
      }

      # The fixture can reach only the public registry.
      require_public_registry() {
        local registry scoped

        registry="$(config_value registry)"
        registry="''${registry:-https://registry.npmjs.org/}"
        scoped="$(config_value @fixture:registry)"

        for url in "$registry" "''${scoped:-$registry}"; do
          if [[ "$url" != https://registry.npmjs.org/ ]]; then
            exit 1
          fi
        done
      }

      case "$1" in
        view)
          require_public_registry
          if [[ "''${PI_UPDATER_FORBID_DISCOVERY:-0}" == 1 ]]; then exit 1; fi
          case "$3" in
            repository)
              printf '%s\n' "$PI_UPDATER_REPOSITORY"
              ;;
            gitHead)
              printf '%s\n' "$PI_UPDATER_GIT_HEAD"
              ;;
            *)
              printf '%s\n' "$PI_UPDATER_VERSION"
              ;;
          esac
          ;;
        install)
          require_public_registry

          # npm keeps an existing package-lock.json. With an
          # npm-shrinkwrap.json, it updates that file and writes no
          # package-lock.json. It takes resolved versions from a yarn.lock,
          # which the fixture writes as a lockfile. A resolution records the
          # manifest's dependency declarations in the lockfile's root record.
          if [[ ! -e package-lock.json && ! -e npm-shrinkwrap.json ]]; then
            resolution="$PI_UPDATER_LOCK"
            if [[ -e yarn.lock ]]; then
              resolution=yarn.lock
            fi

            jq --compact-output --slurpfile manifest package.json \
              '.packages[""] += ($manifest[0] | with_entries(select(.key == "dependencies" or .key == "peerDependencies")))' \
              "$resolution" >package-lock.json
          fi
          ;;
        ls)
          test "$*" = 'ls --all --package-lock-only'

          # An edge is valid when the locked version equals the requested
          # range, or when the manifest overrides the package to that version.
          jq --exit-status --slurpfile manifest package.json '
            ($manifest[0].overrides // {}) as $overrides
            | .packages as $packages
            | all(
                $packages[] | (.dependencies // {}) | to_entries[];
                $packages["node_modules/" + .key].version as $locked
                | $locked == .value or $overrides[.key] == $locked
              )
          ' package-lock.json >/dev/null
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
      printf '%s\n' "$4" >"$PI_UPDATER_URL"
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
  git = pkgs.writeShellApplication {
    name = "git";
    text = ''
      arguments=()
      for argument in "$@"; do
        if [[ "$argument" == https://github.com/fixture/fixture.git ]]; then
          argument="$PI_UPDATER_GIT_REMOTE"
        fi
        arguments+=("$argument")
      done

      exec ${lib.getExe pkgs.gitMinimal} "''${arguments[@]}"
    '';
  };
  updaters = pkgs.callPackage ./updaters.nix {
    inherit git nix wget;
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
