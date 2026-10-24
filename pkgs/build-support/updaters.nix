# Generators for the package update scripts. Each returns a runnable
# derivation that refreshes a package's pinned version and hashes in the
# working tree. Packages attach one as `passthru.updateScript`, and
# `flake/updaters/outputs.nix` exports them as `update-<name>` apps.
# Packages attach the test of an updater as `passthru.tests.updater`.
{
  bash,
  coreutils,
  diffutils,
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
  wget,
  writeShellApplication,
}: {
  # Run a package's own update script from its directory in the working tree.
  # Use it when the upstream's release metadata needs more than a version
  # number and a per-platform URL, which is all `mkSourcesUpdater` handles.
  mkScriptUpdater = {
    pname,
    script,
    extraRuntimeInputs ? [],
  }:
    writeShellApplication {
      name = "update-${pname}";

      runtimeInputs = [coreutils git jq nix wget] ++ extraRuntimeInputs;

      text = ''
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
  # other variables the URL needs). The helpers from `prefetch.sh`, such as
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

      runtimeInputs = [coreutils git jq nix wget] ++ extraRuntimeInputs;

      text = ''
        cd "$(git rev-parse --show-toplevel)/pkgs/${pname}"

        # shellcheck disable=SC1091
        source "${./prefetch.sh}"

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
  mkNixUpdateUpdater = {
    attr,
    filename ? "pkgs/${attr}/package.nix",
    extraFlags ? [],
    unsetEnv ? [],
  }:
    writeShellApplication {
      name = "update-${attr}";

      runtimeInputs = [git nix nix-update];

      text = ''
        cd "$(git rev-parse --show-toplevel)"

        ${lib.concatMapStringsSep "\n" (name: "unset ${lib.escapeShellArg name}") unsetEnv}

        nix-update --flake --override-filename "${filename}" ${lib.escapeShellArgs extraFlags} "${attr}"
      '';
    };

  # Bump a Pi extension: rewrite `source.json` with the new version and source
  # hash, and regenerate the build's lockfile under `npm-deps/`.
  #
  # The registry decides which version to move to either way, because Pi's own
  # installer would resolve the same version. With `gitHub`, the source is that
  # version's release tag. An unchanged GitHub source uses its committed lock;
  # patched sources and registry tarballs are resolved with npm.
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
  }:
    writeShellApplication {
      name = "update-${pname}";

      runtimeInputs = [coreutils git gnutar patch jq nix nodejs wget];

      text = ''
        cd "$(git rev-parse --show-toplevel)/pkgs/${pname}"

        # shellcheck disable=SC1091
        source "${./prefetch.sh}"

        tmpdir="$(mktemp -d)"
        sourceDir="$tmpdir/source"
        mkdir "$sourceDir"
        # Keep the temporary file beside `source.json` so the rename stays
        # atomic.
        staged="$(mktemp source.json.XXXXXX)"
        stagedLock="$(mktemp npm-deps/package-lock.json.XXXXXX)"
        metadataStages=()
        trap 'rm -rf "''${tmpdir}" "''${staged}" "''${stagedLock}" "''${metadataStages[@]}"' EXIT

        # Leave the caller's npm cache alone; this run only reads metadata.
        export npm_config_cache="''${tmpdir}/npm-cache"

        version="$(npm view "${npmName}" version)"
        current="$(jq -r .version source.json)"

        # Some changes need the lockfile rebuilt without a version bump:
        # moving a package to a GitHub source, or editing `npmDependencies`.
        # `--force` asks for that.
        if [[ "''${version}" == "''${current}" ]]; then
          if [[ "''${1:-}" != "--force" ]]; then
            echo "${pname} is already on the latest version (''${version}); pass --force to resolve it again" >&2
            exit 0
          fi

          echo "Resolving ${pname} ''${version} again" >&2
        else
          echo "Bumping ${pname}: ''${current} -> ''${version}" >&2
        fi

        ${
          if gitHub != null
          then ''
            tag="${tagPrefix}''${version}"
            url="https://github.com/${gitHub.owner}/${gitHub.repo}/archive/refs/tags/''${tag}.tar.gz"

            # `fetchFromGitHub` records the hash of the unpacked tree, so
            # `--unpack` produces the matching value. `nix-prefetch-url` prints
            # base32, and `nix hash convert` turns it into the SRI form.
            hash="$(nix hash convert --hash-algo sha256 --to sri \
              "$(nix-prefetch-url --unpack --type sha256 "''${url}")")"

            tarball="''${tmpdir}/${pname}.tar.gz"
            download "''${url}" "''${tarball}"

            tar -xzf "$tarball" -C "$sourceDir" --strip-components=1

            jq -n --sort-keys \
              --arg version "''${version}" \
              --arg tag "''${tag}" \
              --arg hash "''${hash}" \
              '{version: $version, tag: $tag, hash: $hash}' >"''${staged}"
          ''
          else ''
            tarball="''${tmpdir}/${pname}.tgz"
            download "https://registry.npmjs.org/${npmName}/-/${pname}-''${version}.tgz" "''${tarball}"

            tar -xzf "$tarball" -C "$sourceDir" --strip-components=1

            # A failing `hash_file` inside the `jq` arguments would not
            # change `jq`'s exit status, so `source.json` would be written
            # with an empty `tarballHash`. Assign the hash first so errexit
            # stops the script.
            hash="$(hash_file "''${tarball}")"

            jq -n --sort-keys \
              --arg version "''${version}" \
              --arg hash "''${hash}" \
              '{version: $version, tarballHash: $hash}' >"''${staged}"
          ''
        }
        ${lib.concatMapStringsSep "\n" (sourcePatch: ''
            (cd "$sourceDir" && patch --batch --forward -p1 --input ${lib.escapeShellArg (toString sourcePatch)})
          '')
          patches}
        ${lib.optionalString (npmDependencies != {}) ''
          jq --argjson deps ${lib.escapeShellArg (builtins.toJSON npmDependencies)} \
            --from-file ${./promote-npm-dependencies.jq} \
            "$sourceDir/package.json" >"$sourceDir/package.json.new"
          mv "$sourceDir/package.json.new" "$sourceDir/package.json"
        ''}
        ${lib.optionalString (gitHub == null || patches != [] || npmDependencies != {}) ''
          (cd "$sourceDir" && npm install --package-lock-only --ignore-scripts)
        ''}
        lockfile="$sourceDir/package-lock.json"

        jq --exit-status --arg version "''${version}" --arg name ${lib.escapeShellArg npmName} '
          .packages[""].version == $version
          and .packages[""].name == $name
          and (.lockfileVersion == 2 or .lockfileVersion == 3)
        ' "''${lockfile}" >/dev/null
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (destination: sourcePath: ''
            stagedFile="$(mktemp ${lib.escapeShellArg "${destination}.XXXXXX"})"
            metadataStages+=("$stagedFile")
            tar -xOzf "$tarball" --wildcards ${lib.escapeShellArg "*/${sourcePath}"} >"$stagedFile"
            jq --exit-status 'type == "object"' "$stagedFile" >/dev/null
          '')
          metadataFiles)}
        cp "''${lockfile}" "''${stagedLock}"
        mv "''${stagedLock}" npm-deps/package-lock.json
        mv "''${staged}" source.json
        ${lib.concatStringsSep "\n" (lib.imap0 (index: destination: ''mv "''${metadataStages[${toString index}]}" ${lib.escapeShellArg destination}'') (lib.attrNames metadataFiles))}

        echo "Updated ${pname} to ''${version}." >&2
      '';
    };

  mkFlakeBranchUpdater = {input}:
    writeShellApplication {
      name = "update-${input}";

      runtimeInputs = [git nix];

      text = ''
        cd "$(git rev-parse --show-toplevel)"

        nix flake update ${lib.escapeShellArg input}
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
        nix flake update "${input}"
      '';
    };
}
