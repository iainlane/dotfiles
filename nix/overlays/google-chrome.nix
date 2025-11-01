# On Darwin, google-chrome is installed via Homebrew rather than nixpkgs
# (whose updater is broken for macOS). This overlay provides a thin wrapper so
# that anything depending on `pkgs.google-chrome` (e.g. the Playwright MCP
# server) resolves to the system-installed Chrome at runtime.
final: prev:
prev.lib.optionalAttrs prev.stdenv.isDarwin {
  google-chrome = prev.writeShellScriptBin "google-chrome" ''
    app_path=$(mdfind 'kMDItemCFBundleIdentifier == "com.google.Chrome"' | head -1)
    if [ -z "$app_path" ]; then
      echo "error: Google Chrome not found" >&2
      exit 1
    fi
    exec "$app_path/Contents/MacOS/Google Chrome" "$@"
  '';
}
