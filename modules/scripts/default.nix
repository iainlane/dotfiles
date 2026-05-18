_: let
  homeManagerModule = {pkgs, ...}: {
    home.packages = [
      (pkgs.writeShellApplication {
        name = "nix-store-info";
        runtimeInputs = with pkgs; [coreutils findutils gawk gnugrep gnused nix];
        text = builtins.readFile ./nix-store-info.bash;
      })
      (pkgs.writeShellScriptBin "is-dark-mode" ''
        set -euo pipefail

        case "$OSTYPE" in
            darwin*)
                os="macos"
                ;;
            linux*)
                os="linux"
                ;;
            *)
                os="unknown"
                ;;
        esac

        case "$os" in
            macos)
                theme="$(defaults read -g AppleInterfaceStyle 2>/dev/null || echo "")"
                [[ "$theme" == "Dark" ]]
                ;;

            linux)
                if ! command -v dbus-send >/dev/null 2>&1; then
                    echo "Error: dbus-send is not available. Please install it first." >&2
                    exit 1
                fi

                result="$(dbus-send \
                    --session \
                    --print-reply=literal \
                    --reply-timeout=1000 \
                    --dest=org.freedesktop.portal.Desktop \
                    /org/freedesktop/portal/desktop \
                    org.freedesktop.portal.Settings.Read \
                    string:org.freedesktop.appearance \
                    string:color-scheme)"

                [[ "$result" == *"uint32 1"* ]]
                ;;

            *)
                echo "Unsupported operating system: $os" >&2
                exit 1
                ;;
        esac
      '')
    ];
  };
in {
  flake.modules.scripts.homeManagerModules = [homeManagerModule];
}
