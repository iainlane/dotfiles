{
  config,
  hermesBuilders,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = config.dotfiles.hermes;

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

  browserProfile = "/data/.hermes/chromium";

  inherit (hermesBuilders) hermesStateVolume;

  prepareBrowserProfile = pkgs.writeShellApplication {
    name = "hermes-prepare-browser-profile";
    runtimeInputs = [pkgs.coreutils config.virtualisation.podman.package];
    text = ''
      state="$(podman volume inspect --format '{{.Mountpoint}}' ${hermesStateVolume})"

      rm -f "$state"/.hermes/chromium/Singleton{Lock,Socket,Cookie}
    '';
  };
in {
  dotfiles.hermes = {
    agentPackages = [
      agentBrowser
      chromium
      # Fontconfig reads /etc/fonts; its default output only supplies tools.
      pkgs.fontconfig.out
    ];

    environment = {
      AGENT_BROWSER_EXECUTABLE_PATH = lib.mkDefault (lib.getExe chromium);
      AGENT_BROWSER_PROFILE = lib.mkDefault browserProfile;
    };
  };

  # Chromium records the hostname and pid that use a profile in
  # `SingletonLock`. A new container has a new hostname, so Chromium cannot
  # reclaim a lock left by the previous container. No other process uses this
  # profile before agent-browser starts, so a lock at gateway startup is stale.
  virtualisation.quadlet.containers.${cfg.container.name}.serviceConfig.ExecStartPre =
    lib.mkAfter ["${prepareBrowserProfile}/bin/hermes-prepare-browser-profile"];
}
