# Shared infrastructure for the Hermes Agent and its sidecars: the image
# builder, the in-container user, podman hardening, and the agent container
# template. Each platform and feature module imports this and builds on it.
{
  config,
  inputs,
  lib,
  pkgs,
}: let
  cfg = config.services.hermes-agent;

  yaml = pkgs.formats.yaml {};

  generatedConfigFile = yaml.generate "hermes-config.yaml" cfg.settings;

  # Add an extra Python package as a leaf on the agent's import path: drop
  # its propagated deps so they cannot duplicate packages the sealed venv
  # already ships, which the package's collision check rejects. Shared deps
  # resolve from the venv at import; a dependency the venv lacks must be its
  # own `extraPythonPackages` entry.
  venvLeafPackage = pkg:
    pkg.overridePythonAttrs (_: {
      dependencies = [];
      propagatedBuildInputs = [];
      # The package is built without its declared deps, so skip the build's
      # own dependency and test checks; they are satisfied at the agent's
      # assembled import path, not by the package in isolation.
      doCheck = false;
      dontCheckRuntimeDeps = true;
    });

  package =
    if cfg.package != null
    then cfg.package
    else
      inputs.hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default.override {
        inherit (cfg) extraDependencyGroups;
        extraPythonPackages = map venvLeafPackage cfg.extraPythonPackages;
      };

  hermesBinDir = "${package}/bin";

  # Each container runs from a self-contained layered image built from the
  # Nix closure, loaded via a `podman.images` quadlet. There is no host
  # `/nix/store` bind mount; the package lives inside the image at its store
  # path.
  inherit (import ../../lib/container-image.nix {inherit pkgs;}) mkNixImage;

  # A fixed in-container service user, which the shared range maps onto the
  # host. `fakeNss` already provides root and nobody plus nsswitch.conf; we
  # just add the `hermes` line.
  hermesUser = "hermes";

  hermesUid = 1000;

  hermesNss = pkgs.dockerTools.fakeNss.override {
    extraPasswdLines = ["${hermesUser}:x:${toString hermesUid}:${toString hermesUid}:${hermesUser}:/home/hermes:/bin/sh"];
    extraGroupLines = ["${hermesUser}:x:${toString hermesUid}:"];
  };

  # The agent, the dashboard and signal-cli hand files to one another through
  # shared volumes, so they take their maps from one reserved range and a file
  # one writes is one the others can read.
  idRange = config.virtualisation.containers.idRanges.hermes;

  # Podman-managed named volumes hold the durable state. The setup step and
  # backup resolve their mountpoints at runtime via `podman volume inspect`.
  hermesStateVolume = "hermes-state";

  hermesHomeVolume = "hermes-home";

  hermesCacheVolume = "hermes-cache";

  # Where the profile-picture source is mounted in any container that reads it
  # (the rotation helper, and signal-cli, which resolves the avatar path itself).
  profilePictureContainerPath = "/profile-pictures";

  # Tools the agent can shell out to, on top of the package's own runtime
  # deps (git/node/ripgrep/ffmpeg/...). `agentPackages` are nixpkgs
  # attribute names; they go into the image and onto the container PATH so
  # they resolve by name for the agent.
  agentToolDrvs =
    map (name: pkgs.${name}) cfg.agentPackages
    ++ cfg.extraPackages;

  agentBinPath = lib.makeBinPath agentToolDrvs;

  # extraPlugins are symlinked into the state dir by the setup script using
  # their store paths. The container has no host /nix/store, so carry those
  # paths into the image closure here (buildLayeredImage ships the whole
  # closure), otherwise the symlinks dangle inside the container. linkFarm
  # references the plugins as real build inputs, so the closure includes
  # them even though their paths reach the script context-free.
  extraPluginPaths = pkgs.linkFarm "hermes-extra-plugins" (
    lib.mapAttrsToList (name: path: {inherit name path;}) cfg.extraPlugins
  );

  hermesImage = mkNixImage cfg.container.name (
    [
      package
      pkgs.bashInteractive
      # A common Unix userland the agent shells out to, on top of the
      # package's own runtime deps. The minimal image ships none of these.
      pkgs.coreutils
      pkgs.diffutils
      pkgs.file
      pkgs.findutils
      pkgs.gawk
      pkgs.gnugrep
      pkgs.gnused
      pkgs.less
      pkgs.perl
      pkgs.python3
      pkgs.which
      pkgs.dockerTools.binSh
      pkgs.dockerTools.caCertificates
      hermesNss
    ]
    ++ agentToolDrvs
    ++ lib.optional cfg.mcp.enable pkgs.mcp-nixos
    ++ lib.optional (cfg.extraPlugins != {}) extraPluginPaths
  );

  hermesImageUnit = "${cfg.container.name}-image.service";

  # Sandbox hardening shared by every container.
  hardening = {
    dropCapabilities = ["ALL"];
    noNewPrivileges = cfg.container.noNewPrivileges;
    inherit (idRange) uidMaps gidMaps;
  };

  podmanPackage = config.virtualisation.podman.package;

  cliScript = pkgs.writeShellApplication {
    name = "hermes-agent-container-cli";

    text = ''
      program="$(basename "$0")"

      case "$program" in
        hermes|hermes-agent|hermes-acp) ;;
        *) program="hermes" ;;
      esac

      tty_arg="-i"
      if [ -t 0 ]; then
        tty_arg="-it"
      fi

      exec sudo ${podmanPackage}/bin/podman exec "$tty_arg" -u ${hermesUser} \
        -e "TERM=''${TERM-}" \
        -e "COLORTERM=''${COLORTERM-}" \
        -e "LANG=''${LANG-}" \
        "${cfg.container.name}" \
        "${hermesBinDir}/$program" "$@"
    '';
  };

  # The script reads the sub-command off the name it was called by, so each
  # one is a link to it.
  hostCliPackage = pkgs.runCommand "hermes-agent-cli" {} ''
    mkdir -p "$out/bin"

    for name in hermes-agent-container-cli hermes hermes-agent hermes-acp; do
    	ln -s ${cliScript}/bin/hermes-agent-container-cli "$out/bin/$name"
    done
  '';

  envFile = pkgs.writeText "hermes-env" (
    lib.concatStringsSep "\n" (
      lib.mapAttrsToList
      (name: value: "${name}=${value}")
      cfg.environment
    )
  );

  # Everything the agent needs in place before it starts: the state tree, the
  # package it is running, the file that tells the host CLI how to reach it,
  # and the environment assembled from the sops-rendered files.
  setupScript = pkgs.writeShellApplication {
    name = "hermes-prepare-state";

    runtimeInputs = with pkgs; [
      coreutils
      findutils
      gnused
      podmanPackage
    ];

    text =
      ''
        state="$(podman volume inspect --format '{{.Mountpoint}}' ${hermesStateVolume})"

        # This runs on the host, so what it creates is given the host id the
        # container's `hermes` user maps to.
        owner=${toString (idRange.start + hermesUid)}

        install -d -m 0700 -o "$owner" -g "$owner" "$state"

        for dir in .hermes .hermes/cron .hermes/logs .hermes/memories \
          .hermes/plugins .hermes/sessions workspace; do
        	install -d -m 0700 -o "$owner" -g "$owner" "$state/$dir"
        done

        ln -sfn "${package}" "$state/current-package"

        # The skill curator materialises bundled skills read-only (copied
        # from the read-only image). Make the tree writable so the agent can
        # author and edit skills in place.
        if [ -d "$state/.hermes/skills" ]; then
          chmod -R u+w "$state/.hermes/skills"
        fi

        cat > "$state/.hermes/.container-mode" <<'HERMES_CONTAINER_MODE_EOF'
        backend=podman
        container_name=${cfg.container.name}
        exec_user=${hermesUser}
        hermes_bin=${hermesBinDir}/hermes
        HERMES_CONTAINER_MODE_EOF

        sed -i 's/^          //' "$state/.hermes/.container-mode"
        chmod 0600 "$state/.hermes/.container-mode"
        chown "$owner:$owner" "$state/.hermes/.container-mode"

        install -m 0600 -o "$owner" -g "$owner" "${envFile}" "$state/.hermes/.env"
      ''
      + lib.concatMapStrings
      (file: ''

        if [ -f "${file}" ]; then
          printf '\n' >> "$state/.hermes/.env"
          cat "${file}" >> "$state/.hermes/.env"
        fi
      '')
      cfg.environmentFiles
      # Values with spaces survive the round trip through python-dotenv
      # because the entry is written quoted.
      + lib.concatStrings (
        lib.mapAttrsToList
        (name: path: ''

          if [ -f "$state/${path}" ]; then
            printf '\n${name}="%s"\n' "$(cat "$state/${path}")" >> "$state/.hermes/.env"
          fi
        '')
        cfg.environmentFromState
      )
      + ''

        find "$state/.hermes/plugins" -maxdepth 1 -type l -name 'nix-managed-*' -delete
      ''
      + lib.concatStringsSep "\n" (
        lib.mapAttrsToList
        (name: plugin: ''

          if [ ! -f "${plugin}/plugin.yaml" ]; then
            echo "ERROR: extraPlugins entry '${name}' has no plugin.yaml" >&2
            exit 1
          fi

          ln -sfn "${plugin}" "$state/.hermes/plugins/nix-managed-${name}"
        '')
        cfg.extraPlugins
      );
  };

  # Both the gateway and the dashboard are the same image and the same
  # `hermes` binary run with a different sub-command. This builds the shared
  # container definition; callers vary only the sub-command, ports, and a
  # few unit knobs.
  mkHermesContainer = {
    description,
    exec,
    networks ? [],
    publishPorts ? [],
    environments ? {},
    after ? [],
    serviceConfig ? {},
  }: {
    autoStart = true;

    containerConfig =
      hardening
      // {
        inherit exec networks publishPorts;

        image = config.virtualisation.quadlet.images.${cfg.container.name}.ref;

        # Runs as the fixed `hermes` user, non-root inside the namespace and a
        # subordinate id on the host, so it writes its state mounts and
        # nothing else.
        user = hermesUser;

        entrypoint = "${hermesBinDir}/hermes";

        volumes =
          [
            "${hermesStateVolume}.volume:/data"
            "${hermesHomeVolume}.volume:/home/hermes"
            "${hermesCacheVolume}.volume:/data/.hermes/cache"
            # config.yaml and SOUL.md come straight from the Nix store, read
            # only. Hermes never writes them, and a change flips the store path,
            # so the unit changes and the container restarts to pick it up.
            "${generatedConfigFile}:/data/.hermes/config.yaml:ro"
          ]
          ++ lib.optional cfg.soul.enable "${cfg.soul.file}:/data/.hermes/SOUL.md:ro"
          ++ lib.optional cfg.agents.enable "${cfg.agents.file}:/data/workspace/AGENTS.md:ro"
          ++ cfg.container.extraVolumes;

        environments =
          {
            HOME = "/home/hermes";
            HERMES_CONTAINER = "true";
            HERMES_HOME = "/data/.hermes";
            HERMES_MANAGED = "true";
            PATH = "${hermesBinDir}:${agentBinPath}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
          }
          // environments;

        podmanArgs = cfg.container.extraPodmanArgs;
      }
      // lib.optionalAttrs (cfg.container.memory != null) {
        inherit (cfg.container) memory;
      }
      // lib.optionalAttrs (cfg.container.pidsLimit != null) {
        inherit (cfg.container) pidsLimit;
      };

    unitConfig = {
      Description = description;
      After = ["network-online.target" "sops-install-secrets.service" hermesImageUnit] ++ after;
      Wants = ["network-online.target" "sops-install-secrets.service" hermesImageUnit] ++ after;
    };

    serviceConfig =
      {
        ExecStartPre = ["${setupScript}/bin/hermes-prepare-state"];
      }
      // serviceConfig;
  };
in {
  inherit
    mkNixImage
    hermesUser
    hermesNss
    hermesStateVolume
    hermesHomeVolume
    hermesCacheVolume
    profilePictureContainerPath
    hermesImage
    hardening
    hostCliPackage
    mkHermesContainer
    idRange
    ;
}
