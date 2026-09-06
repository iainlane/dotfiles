# Shared infrastructure for the Hermes Agent and its sidecars: the image
# builder, the in-container user, podman hardening, and the agent container
# template. Each platform and feature module imports this and builds on it.
{
  config,
  inputs,
  lib,
  pkgs,
}: let
  cfg = config.dotfiles.hermes;
  quadlet = import ../../lib/quadlet.nix {inherit lib;};

  yaml = pkgs.formats.yaml {};

  generatedConfigFile = yaml.generate "hermes-config.yaml" cfg.settings;

  # Add an extra Python package as a leaf on the agent's import path. The
  # agent package's collision check rejects a package that appears twice, so
  # drop the extra package's propagated dependencies and let the shared ones
  # resolve from the agent's own virtual environment at import time. A
  # dependency that environment does not contain needs its own
  # `extraPythonPackages` entry.
  venvLeafPackage = pkg:
    pkg.overridePythonAttrs (_: {
      dependencies = [];
      propagatedBuildInputs = [];
      # The package is built without its declared dependencies, so its own
      # dependency and test checks would fail. Those dependencies are present
      # on the agent's assembled import path, not in this package alone.
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
  # host. `fakeNss` already provides root and nobody plus nsswitch.conf, so
  # only the `hermes` line is added.
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

  # podman-managed named volumes store the durable state. The setup step and
  # the backup resolve their mountpoints at runtime with
  # `podman volume inspect`.
  hermesStateVolume = "hermes-state";

  hermesHomeVolume = "hermes-home";

  hermesCacheVolume = "hermes-cache";

  # Where the profile-picture source is mounted in any container that reads it
  # (the rotation helper, and signal-cli, which resolves the avatar path itself).
  profilePictureContainerPath = "/profile-pictures";

  # Tools the agent can shell out to, on top of the package's own runtime
  # deps (git/node/ripgrep/ffmpeg/...). They go into the image and onto the
  # container PATH so they resolve by name for the agent.
  agentToolDrvs = cfg.agentPackages ++ cfg.extraPackages;

  agentBinPath = lib.makeBinPath agentToolDrvs;

  # The setup script symlinks each `extraPlugins` entry into the state
  # directory by its store path. The container has no host /nix/store, so those
  # paths have to be in the image closure or the symlinks dangle inside the
  # container. `linkFarm` references the plugins as real build inputs, which
  # puts them in the closure `buildLayeredImage` ships; the script's own copies
  # of the paths carry no string context.
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
    ++ lib.optional cfg.mcp.present pkgs.mcp-nixos
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
        hermes | hermes-agent | hermes-acp)
          ;;

        *)
          program="hermes"
          ;;
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

  # The script reads the sub-command from the name it was invoked as, so each
  # name is a symlink to it.
  hostCliPackage = pkgs.runCommand "hermes-agent-cli" {} ''
    mkdir -p "$out/bin"

    for name in hermes-agent-container-cli hermes hermes-agent hermes-acp; do
    	ln -s ${cliScript}/bin/hermes-agent-container-cli "$out/bin/$name"
    done
  '';

  # Both writers of `.hermes/.env` quote the value and escape the quotation
  # marks and backslashes inside it, so a value containing a space or a
  # quotation mark is parsed correctly by python-dotenv. `builtins.toJSON` of a
  # string produces exactly the double-quoted, backslash-escaped form dotenv
  # reads.
  envFile = pkgs.writeText "hermes-env" (
    lib.concatStringsSep "\n" (
      lib.mapAttrsToList
      (name: value: "${name}=${builtins.toJSON value}")
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

        # Hermes copies the bundled skills out of the read-only image, so they
        # arrive read-only. Make the tree writable so the agent can write and
        # edit skills in place.
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
      + lib.concatStrings (
        lib.mapAttrsToList
        (name: path: ''

          if [ -f "$state/${path}" ]; then
            value="$(cat "$state/${path}")"
            value="''${value//\\/\\\\}"
            value="''${value//\"/\\\"}"
            printf '\n${name}="%s"\n' "$value" >> "$state/.hermes/.env"
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

  # The networks the gateway, the dashboard and the profile-picture helper all
  # join. When Signal is present they also join its network, so the gateway can
  # reach signal-cli and the profile-picture helper can set the avatar through
  # the same daemon.
  hermesNetworks =
    lib.toList cfg.container.network
    ++ lib.optional cfg.signal.present "${cfg.signal.network}.network";

  # The gateway and the dashboard run the same image and the same `hermes`
  # binary with a different sub-command. This builds the shared container
  # definition; callers vary the sub-command, the ports and a few unit
  # settings.
  mkHermesContainer = {
    description,
    exec,
    networks ? hermesNetworks,
    publishPorts ? [],
    environments ? {},
    environmentFiles ? [],
    after ? [],
    serviceConfig ? {},
  }: {
    autoStart = true;

    containerConfig =
      hardening
      // {
        inherit exec networks publishPorts environmentFiles;

        image = config.virtualisation.quadlet.images.${cfg.container.name}.ref;

        # Runs as the fixed `hermes` user, non-root inside the namespace and
        # mapped to a reserved subordinate id on the host. The state volumes
        # are owned by that id, so the process can write them.
        user = hermesUser;

        entrypoint = "${hermesBinDir}/hermes";

        volumes =
          quadlet.mounts [
            {
              source.quadletVolume = hermesStateVolume;
              target = "/data";
            }
            {
              source.quadletVolume = hermesHomeVolume;
              target = "/home/hermes";
            }
            {
              source.quadletVolume = hermesCacheVolume;
              target = "/data/.hermes/cache";
            }
            # config.yaml, SOUL.md and AGENTS.md come straight from the Nix
            # store, read only. Hermes never writes them, and a change flips
            # the store path, so the unit changes and the container restarts
            # to pick it up.
            {
              source.bind = generatedConfigFile;
              target = "/data/.hermes/config.yaml";
              readOnly = true;
            }
          ]
          ++ lib.optionals cfg.soul.present (quadlet.mounts [
            {
              source.bind = cfg.soul.file;
              target = "/data/.hermes/SOUL.md";
              readOnly = true;
            }
          ])
          ++ lib.optionals cfg.agents.present (quadlet.mounts [
            {
              source.bind = cfg.agents.file;
              target = "/data/workspace/AGENTS.md";
              readOnly = true;
            }
          ])
          ++ quadlet.mounts cfg.container.extraVolumes;

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
        Restart = "always";
        RestartSec = 5;
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
    hermesNetworks
    hardening
    hostCliPackage
    mkHermesContainer
    idRange
    ;
}
