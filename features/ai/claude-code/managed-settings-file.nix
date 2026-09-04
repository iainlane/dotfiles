{
  pkgs,
  settings,
}: let
  generated = (pkgs.formats.json {}).generate "managed-settings.json" settings;

  # Claude watches the resolved file's parent directory. Keep the file in a
  # dedicated store directory so Nix store changes do not make Claude scan every
  # top-level store entry.
  directory = pkgs.runCommandLocal "claude-code-managed-settings" {} ''
    install -Dm444 ${generated} "$out/managed-settings.json"
  '';
in "${directory}/managed-settings.json"
