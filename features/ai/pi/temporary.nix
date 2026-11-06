{
  pkgs,
  package,
  assets,
}: let
  inherit (pkgs) lib;
  permissionConfig = import ./permission-config.nix {inherit pkgs;};
in
  pkgs.writeShellApplication {
    name = "pi";
    runtimeInputs = [pkgs.coreutils pkgs.jq];
    text = ''
      umask 077
      source_agent="''${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
      case "$source_agent" in
        \~ | \~/*) source_agent="$HOME''${source_agent:1}" ;;
      esac
      source_xdg="''${XDG_CONFIG_HOME:-$HOME/.config}"
      runtime="$(mktemp -d "''${TMPDIR:-/tmp}/pi-flake.XXXXXXXX")"
      mkdir "$runtime/agent" "$runtime/xdg" "$runtime/agent/extensions"
      shopt -s nullglob dotglob

      for entry in ${assets}/.pi/agent/*; do
        name=$(basename "$entry")
        if [[ "$name" == extensions ]]; then
          continue
        fi
        ln -s "$entry" "$runtime/agent/$name"
      done
      ln -s ${assets}/.pi/agent/extensions/subagent "$runtime/agent/extensions/subagent"
      ${lib.getExe permissionConfig} "$runtime/agent/extensions/pi-permission-system/config.json"
      for entry in ${assets}/.config/*; do
        ln -s "$entry" "$runtime/xdg/$(basename "$entry")"
      done
      for entry in "$source_xdg"/*; do
        target="$runtime/xdg/$(basename "$entry")"
        if [[ ! -e "$target" && ! -L "$target" ]]; then
          ln -s "$entry" "$target"
        fi
      done
      for name in models.json keybindings.json; do
        if [[ -f "$source_agent/$name" && ! -e "$runtime/agent/$name" ]]; then
          install -m600 "$source_agent/$name" "$runtime/agent/$name"
        fi
      done

      printf '{}\n' > "$runtime/agent/auth.json"
      if [[ -f "$source_agent/auth.json" ]]; then
        if jq '
          def valid:
            type == "object" and .type == "api_key"
            and ((has("key") | not) or (.key | type == "string"))
            and ((has("env") | not) or (.env | type == "object" and all(.[]; type == "string")));
          if type == "object" then
            with_entries(select(.value | valid))
            | map_values({type: "api_key"}
              + (if has("key") then {key} else {} end)
              + (if has("env") then {env} else {} end))
          else {} end
        ' "$source_agent/auth.json" > "$runtime/agent/auth.tmp" 2>/dev/null; then
          mv "$runtime/agent/auth.tmp" "$runtime/agent/auth.json"
        else
          rm -f "$runtime/agent/auth.tmp"
          printf '%s\n' 'Pi could not reuse API keys from the installed auth file.' >&2
        fi
      fi

      export PI_CODING_AGENT_DIR="$runtime/agent"
      export PI_CODING_AGENT_SESSION_DIR="$runtime/agent/sessions"
      export PRETTY_CONFIG_DIR="$runtime/agent"
      export PI_LENS_CONFIG_PATH=${assets}/.pi-lens/config.json
      export XDG_CONFIG_HOME="$runtime/xdg"
      exec ${lib.getExe package} "$@"
    '';
  }
