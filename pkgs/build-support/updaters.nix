# Generators for the package update scripts. Each returns a runnable
# derivation that refreshes a package's pinned version and hashes in the
# working tree. Packages attach one as `passthru.updateScript`, and
# `flake/parts/updaters.nix` surfaces them all as `update-<name>` apps.
{
  coreutils,
  gh,
  git,
  gnugrep,
  gnused,
  gnutar,
  jq,
  lib,
  nix,
  nix-update,
  nodejs,
  wget,
  writeShellApplication,
}: {
  # Regenerate a package's `sources.json`: discover the latest upstream
  # version, then download and hash one prebuilt binary per platform.
  #
  # `discoverVersion` is a shell fragment that must set `version` (and any
  # other variables the URL needs). The helpers from `prefetch.sh`, such as
  # `download`, are in scope. `urlTemplate` is a shell-syntax string expanded
  # once per platform with `suffix`, `version`, and anything `discoverVersion`
  # set; write its `${...}` references with a backslash so Nix leaves them for
  # the shell.
  mkSourcesUpdater = {
    pname,
    # Nix system → upstream artifact suffix, e.g. "x86_64-linux" → "linux_amd64".
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

        write_sources "''${version}" "''${pairs[@]}" >sources.json

        echo "Updated sources.json to ${pname} ''${version}." >&2
      '';
    };

  # Bump a package whose derivation nix-update understands: version, source
  # hash, and dependency hashes such as `vendorHash` or `pnpmDeps`.
  mkNixUpdateUpdater = {
    attr,
    extraFlags ? [],
  }:
    writeShellApplication {
      name = "update-${attr}";

      runtimeInputs = [git nix nix-update];

      text = ''
        cd "$(git rev-parse --show-toplevel)"

        nix-update --flake --override-filename "pkgs/${attr}/package.nix" ${lib.escapeShellArgs extraFlags} "${attr}"
      '';
    };

  # Bump a Pi extension packaged from its npm registry tarball. It reads the
  # latest version from the registry, writes that version and the new tarball
  # hash to `source.json`, and regenerates the lockfile under `npm-deps/` that
  # `importNpmLock` resolves `node_modules` from, so a version bump needs no
  # hand editing.
  mkPiExtensionUpdater = {
    npmName,
    pname,
    # Replacement version ranges, applied to the manifest's `dependencies`
    # before resolving, for a dependency whose declared range admits a version
    # the extension cannot use.
    npmDependencies ? {},
  }:
    writeShellApplication {
      name = "update-${pname}";

      runtimeInputs = [coreutils git gnutar jq nix nodejs wget];

      text = ''
        cd "$(git rev-parse --show-toplevel)/pkgs/${pname}"

        # shellcheck disable=SC1091
        source "${./prefetch.sh}"

        tmpdir="$(mktemp -d)"
        trap 'rm -rf "''${tmpdir}"' EXIT

        # Leave the caller's npm cache alone; this run only reads metadata.
        export npm_config_cache="''${tmpdir}/npm-cache"

        version="$(npm view ${npmName} version)"
        current="$(jq -r .version source.json)"

        # A change to `npmDependencies` needs a new lockfile without a new
        # upstream version, which `--force` asks for.
        if [[ "''${version}" == "''${current}" ]]; then
          if [[ "''${1:-}" != "--force" ]]; then
            echo "${pname} is already on the latest version (''${version}); pass --force to resolve it again" >&2
            exit 0
          fi

          echo "Resolving ${pname} ''${version} again" >&2
        else
          echo "Bumping ${pname}: ''${current} -> ''${version}" >&2
        fi

        tarball="''${tmpdir}/${pname}.tgz"
        download "https://registry.npmjs.org/${npmName}/-/${pname}-''${version}.tgz" "''${tarball}"

        tar -xzf "''${tarball}" -C "''${tmpdir}" package/package.json

        ${lib.optionalString (npmDependencies != {}) ''
          manifest="''${tmpdir}/package/package.json"
          jq --argjson deps '${builtins.toJSON npmDependencies}' \
            '.dependencies += $deps' "''${manifest}" >"''${manifest}.new"
          mv "''${manifest}.new" "''${manifest}"
        ''}

        # npm resolves beside the manifest, but only the lockfile is
        # committed: the build reads what it needs from the lockfile's root
        # record. `--ignore-scripts` because this run wants a lockfile alone,
        # and npm would otherwise run the package's `prepare` script.
        (cd "''${tmpdir}/package" && npm install --package-lock-only --ignore-scripts)
        cp "''${tmpdir}/package/package-lock.json" npm-deps/package-lock.json

        jq -n --sort-keys \
          --arg version "''${version}" \
          --arg hash "$(hash_file "''${tarball}")" \
          '{version: $version, tarballHash: $hash}' >source.json

        echo "Updated ${pname} to ''${version}." >&2
      '';
    };

  # Bump a flake input pinned to an immutable release tag in its URL, which
  # `nix flake update` cannot move on its own: read the latest GitHub release,
  # rewrite the tag in flake.nix, and re-lock.
  mkFlakeInputUpdater = {
    input,
    repo,
  }:
    writeShellApplication {
      name = "update-${input}";

      runtimeInputs = [gh git gnugrep gnused nix];

      text = ''
        cd "$(git rev-parse --show-toplevel)"

        if ! latest_tag="$(gh api "repos/${repo}/releases/latest" --jq .tag_name)"; then
          echo "could not fetch the latest ${input} release from GitHub" >&2
          exit 1
        fi

        current_tag="$(grep -oE "github:${repo}/[^\"]+" flake.nix | head -n1)"
        current_tag="''${current_tag##*/}"

        if [[ "''${current_tag}" == "''${latest_tag}" ]]; then
          echo "${input} is already on the latest release (''${latest_tag})" >&2
          exit 0
        fi

        echo "Bumping ${input}: ''${current_tag} -> ''${latest_tag}" >&2
        sed -E -i "s#(github:${repo})/[^\"]+#\1/''${latest_tag}#" flake.nix

        echo "Re-locking ${input}" >&2
        nix flake update "${input}"
      '';
    };
}
