_: {
  perSystem = {pkgs, ...}: let
    inherit (pkgs) lib;
    settingsFile = import ../../../modules/ai/claude-code/managed-settings-file.nix {
      inherit pkgs;
      settings.test = true;
    };
  in {
    checks.claude-managed-settings-layout =
      pkgs.runCommandLocal "claude-managed-settings-layout" {
        nativeBuildInputs = [pkgs.jq];
      }
      ''
        if [[ $(dirname ${lib.escapeShellArg settingsFile}) == ${lib.escapeShellArg builtins.storeDir} ]]; then
          echo "managed-settings.json is a top-level Nix store file" >&2
          exit 1
        fi

        if [[ -L ${lib.escapeShellArg settingsFile} ]]; then
          echo "managed-settings.json is a symlink" >&2
          exit 1
        fi

        jq --exit-status '.test == true' ${lib.escapeShellArg settingsFile} >/dev/null
        touch $out
      '';
  };
}
