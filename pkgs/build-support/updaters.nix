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
  jq,
  lib,
  nix,
  nix-update,
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
