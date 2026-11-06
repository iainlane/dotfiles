{pkgs}: let
  managed = pkgs.writeText "pi-permission-managed.json" (builtins.toJSON {
    authorizerChain = ["auto-review"];
    permission = {
      "*" = "allow";
      bash = "ask";
    };
  });
in
  pkgs.writeShellApplication {
    name = "configure-pi-permissions";
    runtimeInputs = [pkgs.coreutils pkgs.jq];
    text = ''
      configFile=$1
      previousFile=''${2:-}
      sourceFile=${managed}

      if [[ -L "$configFile" ]]; then
        printf 'Permission-system configuration is a symbolic link: %s\nReplace it with a writable file before activation.\n' "$configFile" >&2
        exit 1
      fi

      if [[ -e "$configFile" ]]; then
        sourceFile=$configFile
      elif [[ -n "$previousFile" && -f "$previousFile" ]]; then
        sourceFile=$previousFile
      fi

      mkdir -p "$(dirname "$configFile")"
      temporary=$(mktemp "$configFile.XXXXXX")
      trap 'rm -f "$temporary"' EXIT
      jq --slurp --slurpfile managed ${managed} '
        if length == 1 and (.[0] | type) == "object" then
          .[0] + $managed[0]
        else
          error("permission-system config must contain one JSON object")
        end
      ' "$sourceFile" >"$temporary"

      if [[ -f "$configFile" ]] && cmp -s "$temporary" "$configFile"; then
        exit 0
      fi

      mv -T "$temporary" "$configFile"
    '';
  }
