{pkgs, ...}: let
  common = import ./common.nix;
  tomlFormat = pkgs.formats.toml {};

  # Voxtype requires these tables whenever a config file exists; this mirrors
  # the base settings of home-manager's services.voxtype module.
  settings = pkgs.lib.recursiveUpdate {
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
  # The daemon itself comes from the Homebrew cask (see darwin-system.nix);
  # the flake's packages are Linux-only. The cask also installs the launch
  # agent and the built-in hotkey (hold Right Option) works on macOS, so only
  # the engine and model need configuring.
  #
  # Voxtype on macOS reads its config from Application Support, not XDG.
  home.file."Library/Application Support/voxtype/config.toml".source =
    tomlFormat.generate "voxtype-config.toml" settings;
}
