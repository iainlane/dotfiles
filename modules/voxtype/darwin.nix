{
  config,
  hostname,
  inputs,
  lib,
  pkgs,
  ...
}: let
  common = import ./common.nix;
  tomlFormat = pkgs.formats.toml {};
  package = pkgs.voxtype-onnx;
  sourceBundle = "${package}/Applications/Voxtype.app";
  appBinary = "/Applications/Voxtype.app/Contents/MacOS/voxtype-bin";
  bundleIdentifier = "io.voxtype.daemon";
  logsDirectory = "${config.home.homeDirectory}/Library/Logs/voxtype";
  secretsFile = inputs.secrets + "/${hostname}/user-voxtype.yaml";
  identitySecret = config.sops.secrets.voxtype-signing-identity-p12.path;
  passwordSecret = config.sops.secrets.voxtype-signing-identity-password.path;
  activationScript = pkgs.writeShellApplication {
    name = "activate-voxtype";
    runtimeInputs = [pkgs.openssl];
    text = builtins.readFile ./activate-darwin.bash;
  };

  # Voxtype requires these tables whenever a config file exists; this mirrors
  # the base settings of home-manager's services.voxtype module.
  settings = pkgs.lib.recursiveUpdate {
    hotkey = {
      key = "FN";
      mode = "push_to_talk";
    };

    audio = {
      device = "default";
      sample_rate = 16000;
      max_duration_secs = 60;
    };

    output = {
      mode = "type";
      fallback_to_clipboard = true;
    };

    osd.enabled = false;
  } (common.settings pkgs);
in {
  home = {
    packages = [package];

    # Voxtype on macOS reads its config from Application Support, not XDG.
    file = {
      "Library/Application Support/voxtype/config.toml".source =
        tomlFormat.generate "voxtype-config.toml" settings;
      "Library/Logs/voxtype/.keep".text = "";
    };

    activation.voxtypeApp = lib.hm.dag.entryAfter ["setupLaunchAgents" "sops-nix"] ''
      if [ -n "$DRY_RUN_CMD" ]; then
        echo "Would install and start the signed Voxtype app"
      else
        ${lib.getExe activationScript} \
          ${lib.escapeShellArg sourceBundle} \
          ${lib.escapeShellArg identitySecret} \
          ${lib.escapeShellArg passwordSecret}
      fi
    '';
  };

  launchd.agents.voxtype = {
    enable = true;
    config = {
      Label = bundleIdentifier;
      ProgramArguments = [appBinary "daemon"];
      EnvironmentVariables.VOXTYPE_NIX_STORE_PATH = sourceBundle;
      RunAtLoad = true;
      KeepAlive = true;
      ProcessType = "Background";
      StandardOutPath = "${logsDirectory}/stdout.log";
      StandardErrorPath = "${logsDirectory}/stderr.log";
    };
  };

  sops.secrets = {
    voxtype-signing-identity-p12 = {
      sopsFile = secretsFile;
      key = "voxtype_signing_identity_p12";
    };
    voxtype-signing-identity-password = {
      sopsFile = secretsFile;
      key = "voxtype_signing_identity_password";
    };
  };
}
