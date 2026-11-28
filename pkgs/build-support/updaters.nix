# Generators for the package update scripts. Each returns a runnable
# derivation that refreshes a package's pinned version and hashes in the
# working tree. Packages attach one as `passthru.updateScript`, and
# `flake/updaters/outputs.nix` exports them as `update-<name>` apps.
# Packages attach the test of an updater as `passthru.tests.updater`.
{
  bash,
  coreutils,
  diffutils,
  findutils,
  gh,
  git,
  gnutar,
  jq,
  lib,
  nix,
  nix-update,
  nodejs,
  patch,
  pyright,
  python3,
  ruff,
  runCommandLocal,
  stdenv,
  wget,
  writeShellApplication,
  writeText,
  yq-go,
}: let
  # nix-update and the update scripts read packages from
  # `legacyPackages.<system>.localPackages`. `packages.<system>` leaves out
  # packages that are unavailable on the system, such as Linux-only packages on
  # Darwin, and their updaters still have to run there.
  localPackagesAttr = "legacyPackages.${stdenv.hostPlatform.system}.localPackages";
in {
  inherit localPackagesAttr nix-update;

  # Run a package's own update script from its directory in the working tree.
  # Use it when the upstream's release metadata needs more than a version
  # number and a per-platform URL, which is all `mkSourcesUpdater` handles.
  # `LOCAL_PACKAGES_ATTR` contains the flake attribute path of the local
  # packages for this system.
  mkScriptUpdater = {
    pname,
    script,
    extraRuntimeInputs ? [],
    refreshInputs ? null,
  }: let
    refresh = refreshInputs != null;
  in
    writeShellApplication {
      name = "update-${pname}";
      passthru.maintenance =
        {
          source = "release";
          inherit refresh;
        }
        // lib.optionalAttrs refresh {inherit refreshInputs;};
      runtimeInputs = [coreutils git jq nix wget] ++ extraRuntimeInputs;
      runtimeEnv.LOCAL_PACKAGES_ATTR = localPackagesAttr;

      text = ''
        ${lib.optionalString (!refresh) ''
          if [[ "''${1:-}" == --refresh ]]; then echo 'This updater does not support --refresh.'; exit 1; fi
        ''}
        cd "$(git rev-parse --show-toplevel)/pkgs/${pname}"

        ${builtins.readFile script}
      '';
    };

  # Test the script of a `mkScriptUpdater` updater. The test receives the
  # script's path, followed by `extraArgs`.
  mkScriptUpdaterTest = {
    pname,
    script,
    test,
    extraArgs ? [],
    extraInputs ? [],
  }:
    runCommandLocal "${pname}-updater-test" {
      nativeBuildInputs = [bash diffutils jq] ++ extraInputs;
    } ''
      bash ${test} ${script} ${lib.concatMapStringsSep " " (arg: lib.escapeShellArg "${arg}") extraArgs}
      touch "$out"
    '';

  # Lint, type-check and run the tests of a Python updater. The test module
  # imports the updater as `update`, so both files keep their conventional
  # names in the build directory.
  mkPythonUpdaterTest = {
    pname,
    script,
    test,
  }:
    runCommandLocal "${pname}-updater-test" {
      nativeBuildInputs = [pyright python3 ruff];
    } ''
      cp ${script} update.py
      cp ${test} test_update.py
      ruff check update.py test_update.py
      ruff format --check update.py test_update.py
      pyright --project .
      python3 -m unittest -v
      touch "$out"
    '';

  # Regenerate a package's `sources.json`: discover the latest upstream
  # version, then download and hash one prebuilt binary per platform.
  #
  # `discoverVersion` is a shell fragment that must set `version` (and any
  # other variables the URL needs). The helpers from `prefetch.bash`, such as
  # `download`, are in scope. `urlTemplate` is a shell-syntax string expanded
  # once per platform with `suffix`, `version` and any variable set by
  # `discoverVersion`; write its `${...}` references with a backslash so Nix
  # leaves them for the shell.
  mkSourcesUpdater = {
    pname,
    # Upstream artifact suffix for each Nix system, such as "linux_amd64" for
    # "x86_64-linux".
    platforms,
    discoverVersion,
    urlTemplate,
    extraRuntimeInputs ? [],
  }: let
    platformLines =
      lib.concatStringsSep "\n"
      (lib.mapAttrsToList
        (system: suffix: ''["${system}"]="${suffix}"'')
        platforms);
  in
    writeShellApplication {
      name = "update-${pname}";
      passthru.maintenance = {source = "release";};
      runtimeInputs = [coreutils git jq nix wget] ++ extraRuntimeInputs;

      text = ''
        if (($#)); then echo 'This updater does not accept arguments.'; exit 1; fi
        cd "$(git rev-parse --show-toplevel)/pkgs/${pname}"

        # shellcheck disable=SC1091
        source "${./prefetch.bash}"

        declare -A PLATFORMS=(
        ${platformLines}
        )

        ${discoverVersion}
        echo "Latest version: ''${version}" >&2

        pairs=()
        for system in "''${!PLATFORMS[@]}"; do
          suffix="''${PLATFORMS[''${system}]}"
          pairs+=("''${system}=${urlTemplate}")
        done

        # The downloads happen inside `write_sources`, so writing straight to
        # `sources.json` would truncate it and leave it empty if one of them
        # failed. Keep the temporary file beside the destination so the final
        # rename stays atomic.
        staged="$(mktemp sources.json.XXXXXX)"
        trap 'rm -f "''${staged}"' EXIT

        write_sources "''${version}" "''${pairs[@]}" >"''${staged}"
        mv "''${staged}" sources.json

        echo "Updated sources.json to ${pname} ''${version}." >&2
      '';
    };

  # Bump a package whose derivation nix-update understands: version, source
  # hash, and dependency hashes such as `vendorHash` or `pnpmDeps`.
  #
  # `npmLockfile` is the repository path of a copy of the source's
  # package-lock.json, for a build that reads the lockfile during evaluation.
  # Reading it from the fetched source would be import-from-derivation.
  mkNixUpdateUpdater = {
    attr,
    filename ? "pkgs/${attr}/package.nix",
    extraFlags ? [],
    unsetEnv ? [],
    npmLockfile ? null,
    refresh ? false,
    refreshFlags ? [],
    refreshInputs ? ["nixpkgs"],
  }: let
    flakeAttr = "${localPackagesAttr}.${attr}";
  in
    writeShellApplication {
      name = "update-${attr}";
      passthru.maintenance =
        {
          source = "release";
          inherit refresh;
        }
        // lib.optionalAttrs refresh {inherit refreshInputs;};

      runtimeInputs = [coreutils git nix nix-update];

      text =
        ''
          cd "$(git rev-parse --show-toplevel)"

          ${lib.concatMapStringsSep "\n" (name: "unset ${lib.escapeShellArg name}") unsetEnv}

          if [[ "$#" == 0 ]]; then
            nix-update --flake --override-filename "${filename}" ${lib.escapeShellArgs extraFlags} "${flakeAttr}" >&2
          ${lib.optionalString refresh ''
            elif [[ "$#" == 1 && "$1" == --refresh ]]; then
              nix-update --flake --override-filename "${filename}" --version=skip --no-src ${lib.escapeShellArgs refreshFlags} "${flakeAttr}" >&2
          ''}
          else
            echo 'Unsupported updater arguments.'
            exit 1
          fi
        ''
        + lib.optionalString (npmLockfile != null) ''

          source="$(nix build --no-link --print-out-paths ".#${flakeAttr}.src")"
          install -m 0644 "''${source}/package-lock.json" ${lib.escapeShellArg npmLockfile}
        '';
    };

  # Bump a Pi extension, or pin it to an unreleased upstream commit. See
  # `pi-extension-updater.bash` for the behaviour of each mode.
  mkPiExtensionUpdater = {
    npmName,
    pname,
    # `{owner, repo}` of the source repository, or null for a registry tarball.
    gitHub ? null,
    tagPrefix ? "v",
    # Replacement version ranges for entries in the manifest's `dependencies`,
    # applied before resolving. Use one when a dependency's declared range would
    # let npm pick a version that breaks the extension.
    npmDependencies ? {},
    patches ? [],
    metadataFiles ? {},
  }: let
    config = writeText "update-${pname}.json" (builtins.toJSON {
      inherit npmName pname gitHub tagPrefix npmDependencies patches metadataFiles;
      prefetch = ./prefetch.bash;
      promoteDependencies = ./promote-npm-dependencies.jq;
    });
  in
    writeShellApplication {
      name = "update-${pname}";
      passthru.maintenance = {
        source = "release";
        refresh = true;
        refreshInputs = ["nixpkgs"];
        lockfileMaintenance = true;
      };
      runtimeInputs = [bash coreutils git gnutar patch jq nix nodejs wget];

      text = ''
        cd "$(git rev-parse --show-toplevel)/pkgs/${pname}"
        bash ${./pi-extension-updater.bash} ${config} "$@"
      '';
    };

  # Point a pnpm package's overrides at the local npm packages that it uses,
  # regenerate its lockfile against their tarballs, and refresh its dependency
  # hash. `catalogue` lists the local npm packages that the package can use, as
  # `pnpmCatalogue` in `lib/npm-packages.nix` returns them. With
  # `--maintain-lockfile`, the updater also moves every locked dependency,
  # direct and transitive, to the newest version that its range allows.
  mkPnpmLockUpdater = {
    pname,
    directory,
    catalogue,
    pnpm,
  }: let
    packages = writeText "${pname}-npm-packages.json" (builtins.toJSON catalogue);
  in
    writeShellApplication {
      name = "update-${pname}";
      passthru.maintenance = {
        source = "repository";
        refresh = true;
        refreshInputs = ["nixpkgs"];
        lockfileMaintenance = true;
      };
      runtimeInputs = [bash coreutils findutils git jq pnpm nix nix-update python3 yq-go];
      text = ''
        arguments=()
        case "$*" in
        "" | --refresh)
          ;;
        --maintain-lockfile)
          arguments=(--maintain-lockfile)
          ;;
        --renovate\ *)
          if (($# != 2)); then echo "Expected a Renovate upgrade data file." >&2; exit 1; fi
          arguments=("$@")
          ;;
        *)
          echo ${lib.escapeShellArg "Usage: update-${pname} [--refresh | --maintain-lockfile | --renovate DATA]"} >&2
          exit 1
          ;;
        esac

        root="$(git rev-parse --show-toplevel)"
        cd "$root/${directory}"
        bash ${./pnpm-lock-updater.bash} ${packages} ${./pnpm-providers.bash} "$root" ${./pnpm-renovate.py} "''${arguments[@]}"
        cd "$root"
        nix-update --flake --override-filename ${lib.escapeShellArg "${directory}/package.nix"} --version=skip ${lib.escapeShellArg pname}
      '';
    };

  mkFlakeBranchUpdater = {input}:
    writeShellApplication {
      name = "update-${input}";
      runtimeInputs = [git nix];

      text = ''
        cd "$(git rev-parse --show-toplevel)"

        if (($#)); then echo 'This input updater does not accept arguments.'; exit 1; fi
        nix flake update ${lib.escapeShellArg input} >&2
      '';
    };

  # Bump a flake input pinned to an immutable release tag in its URL, which
  # `nix flake update` cannot move on its own: read the latest GitHub release,
  # rewrite the input's URL in flake.nix, and re-lock.
  mkFlakeInputUpdater = {
    input,
    owner,
    repo,
    # The tag in the input's current URL.
    ref,
  }:
    writeShellApplication {
      name = "update-${input}";

      runtimeInputs = [coreutils gh git jq nix];

      text = ''
        cd "$(git rev-parse --show-toplevel)"

        if (($#)); then echo 'This input updater does not accept arguments.'; exit 1; fi
        current_tag=${lib.escapeShellArg ref}

        if ! latest_tag="$(gh api "repos/${owner}/${repo}/releases/latest" --jq .tag_name)"; then
          echo "Could not fetch the latest ${input} release from GitHub" >&2
          exit 1
        fi

        if [[ "''${current_tag}" == "''${latest_tag}" ]]; then
          echo "${input} is already on the latest release (''${latest_tag})" >&2
          exit 0
        fi

        echo "Bumping ${input}: ''${current_tag} -> ''${latest_tag}" >&2

        # Keep the temporary file beside flake.nix so the rename stays atomic.
        staged="$(mktemp flake.nix.XXXXXX)"
        trap 'rm -f "''${staged}"' EXIT

        jq --raw-input --slurp --join-output \
          --arg old "github:${owner}/${repo}/''${current_tag}" \
          --arg new "github:${owner}/${repo}/''${latest_tag}" \
          --from-file ${./replace-once.jq} \
          flake.nix >"''${staged}"
        mv "''${staged}" flake.nix

        echo "Re-locking ${input}" >&2
        nix flake update "${input}" >&2
      '';
    };
}
