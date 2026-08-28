{
  lib,
  pkgs,
  ...
}: let
  common = import ./common.nix;
  tomlFormat = pkgs.formats.toml {};

  # Voxtype requires these tables whenever a config file exists; this mirrors
  # the base settings of home-manager's services.voxtype module, which is
  # systemd-only.
  settings = pkgs.lib.recursiveUpdate {
    # The built-in hotkey: hold Right Option to record. macOS grants the
    # Input Monitoring permission it needs per binary, so a voxtype update
    # changes the store path and the grant has to be repeated in System
    # Settings.
    hotkey = {};

    audio = {
      device = "default";
      sample_rate = 16000;
      max_duration_secs = 60;
    };

    output = {
      mode = "type";
      fallback_to_clipboard = true;
    };
  } (common.settings pkgs);
in {
  home.packages = [pkgs.voxtype-onnx];

  # Voxtype on macOS reads its config from Application Support, not XDG.
  home.file."Library/Application Support/voxtype/config.toml".source =
    tomlFormat.generate "voxtype-config.toml" settings;

  launchd.agents.voxtype = {
    enable = true;

    config = {
      ProgramArguments = ["${lib.getExe pkgs.voxtype-onnx}" "daemon"];
      RunAtLoad = true;
      KeepAlive.SuccessfulExit = false;
      StandardOutPath = "/tmp/voxtype.log";
      StandardErrorPath = "/tmp/voxtype.err.log";
    };
  };
}
