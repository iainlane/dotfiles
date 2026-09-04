{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.hermes-agent;

  # Chromium cannot use Nixpkgs' SUID helper inside the mapped-user container.
  # Podman supplies the isolation boundary for the unsandboxed browser process.
  chromium = pkgs.chromium.override {
    commandLineArgs = lib.concatStringsSep " " [
      "--no-sandbox"
      "--disable-dev-shm-usage"
      "--headless=new"
      "--window-size=1280,900"
      "--use-gl=angle"
      "--use-angle=swiftshader"
      "--no-first-run"
      "--no-default-browser-check"
    ];
  };

  agentBrowser =
    inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.agent-browser.override
    {inherit chromium;};

  cdpPort = 9222;
  cdpUrl = "http://127.0.0.1:${toString cdpPort}";

  # browser-harness 0.1.13 exits before it can auto-launch a cold browser.
  gateway = pkgs.writeShellApplication {
    name = "hermes-browser-gateway";
    runtimeInputs = [pkgs.coreutils pkgs.curl];
    text = ''
      browser_pid=
      hermes_pid=

      stop_children() {
        trap - EXIT INT TERM
        kill "''${browser_pid}" "''${hermes_pid}" 2>/dev/null || true
        wait "''${browser_pid}" "''${hermes_pid}" 2>/dev/null || true
      }

      trap 'stop_children; exit 143' INT TERM
      trap stop_children EXIT

      ${lib.getExe chromium} \
        --remote-debugging-address=127.0.0.1 \
        --remote-debugging-port=${toString cdpPort} \
        --user-data-dir=/data/.hermes/chromium \
        about:blank &
      browser_pid=$!

      for _ in {1..100}; do
        if curl --fail --silent --output /dev/null ${cdpUrl}/json/version; then
          break
        fi

        if ! kill -0 "''${browser_pid}" 2>/dev/null; then
          wait "''${browser_pid}"
        fi

        sleep 0.1
      done

      curl --fail --silent --output /dev/null ${cdpUrl}/json/version

      /data/.hermes/current-package/bin/hermes "$@" &
      hermes_pid=$!

      status=0
      wait -n "''${browser_pid}" "''${hermes_pid}" || status=$?
      stop_children
      exit "''${status}"
    '';
  };
in {
  config = lib.mkIf cfg.enable {
    services.hermes-agent = {
      agentPackages = [
        agentBrowser
        chromium
        gateway
        # Fontconfig reads /etc/fonts; its default output only supplies tools.
        pkgs.fontconfig.out
      ];

      environment.AGENT_BROWSER_EXECUTABLE_PATH = lib.mkDefault (lib.getExe chromium);
    };

    virtualisation.quadlet.containers.${cfg.container.name}.containerConfig = {
      entrypoint = lib.mkForce (lib.getExe gateway);
      environments.BROWSER_CDP_URL = cdpUrl;
    };
  };
}
