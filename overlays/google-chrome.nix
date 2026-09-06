# On Darwin, Chrome is installed by Homebrew, because the nixpkgs package's
# updater does not work for macOS. Replace `pkgs.google-chrome` with a script
# that finds the installed Chrome and runs it, so a package that launches
# `google-chrome`, such as the Playwright MCP server, starts the browser the
# machine has.
_: _: prev:
prev.lib.optionalAttrs prev.stdenv.hostPlatform.isDarwin {
  google-chrome = prev.writeShellScriptBin "google-chrome" ''
    app_path=$(mdfind 'kMDItemCFBundleIdentifier == "com.google.Chrome"' | head -1)
    if [ -z "$app_path" ]; then
      echo "error: Google Chrome not found" >&2
      exit 1
    fi
    exec "$app_path/Contents/MacOS/Google Chrome" "$@"
  '';
}
