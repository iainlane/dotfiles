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
  # Run a package's own update script from its directory in the working tree.
  # For an upstream whose release metadata needs more than the version number
  # and per-platform URL that `mkSourcesUpdater` handles.
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

  # Bump a Pi extension: rewrite `source.json` with the new version and source
  # hash, and refresh the `npm-deps/` lockfile the build resolves from, so a
  # version bump needs no hand editing.
  #
  # The registry decides which version to move to in both cases, because that
  # is the version Pi's own installer would resolve.
  #
  # With `gitHub`, the source is that version's release tag, and the lockfile
  # is whatever upstream committed there. Without it, the source is the
  # registry tarball, which carries no lockfile, so npm resolves the tarball's
  # manifest here instead.
  mkPiExtensionUpdater = {
    npmName,
    pname,
    # `{owner, repo}` of the source repository, or null for a registry tarball.
    gitHub ? null,
    # The release tag's prefix before the version.
    tagPrefix ? "v",
    # Replacement version ranges, applied to the manifest's `dependencies`
    # before resolving, for a dependency whose declared range admits a version
    # the extension cannot use. Meaningless with `gitHub`, which takes
    # upstream's resolution as it stands.
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
        # Keep the temporary file beside `source.json` so the rename below
        # stays atomic.
        staged="$(mktemp source.json.XXXXXX)"
        trap 'rm -rf "''${tmpdir}" "''${staged}"' EXIT

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
            # `--unpack` is what produces a matching value. It prints base32,
            # which `nix hash convert` turns into the SRI form Nix expects.
            hash="$(nix hash convert --hash-algo sha256 --to sri \
              "$(nix-prefetch-url --unpack --type sha256 "''${url}")")"

            tarball="''${tmpdir}/${pname}.tar.gz"
            download "''${url}" "''${tarball}"

            # GitHub wraps the archive in one directory named after the repo
            # and tag. Strip that level and match by wildcard, so the tag
            # naming scheme does not have to be spelled out here.
            tar -xzf "''${tarball}" -C "''${tmpdir}" --strip-components=1 \
              --wildcards '*/package-lock.json'

            cp "''${tmpdir}/package-lock.json" npm-deps/package-lock.json

            jq -n --sort-keys \
              --arg version "''${version}" \
              --arg tag "''${tag}" \
              --arg hash "''${hash}" \
              '{version: $version, tag: $tag, hash: $hash}' >"''${staged}"
          ''
          else ''
            tarball="''${tmpdir}/${pname}.tgz"
            download "https://registry.npmjs.org/${npmName}/-/${pname}-''${version}.tgz" "''${tarball}"

            tar -xzf "''${tarball}" -C "''${tmpdir}" package/package.json

            ${lib.optionalString (npmDependencies != {}) ''
              manifest="''${tmpdir}/package/package.json"
              jq --argjson deps '${builtins.toJSON npmDependencies}' \
                --from-file ${./promote-npm-dependencies.jq} \
                "''${manifest}" >"''${manifest}.new"
              mv "''${manifest}.new" "''${manifest}"
            ''}

            # npm resolves beside the manifest, but only the lockfile is
            # committed: the build reads what it needs from the lockfile's root
            # record. Pass `--ignore-scripts`: only the lockfile is wanted here,
            # and a plain install runs the package's `prepare` script.
            (cd "''${tmpdir}/package" && npm install --package-lock-only --ignore-scripts)
            cp "''${tmpdir}/package/package-lock.json" npm-deps/package-lock.json

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
        mv "''${staged}" source.json

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
          echo "Could not fetch the latest ${input} release from GitHub" >&2
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
