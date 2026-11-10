{
  upstreamPackage,
  stdenv,
  writeShellScriptBin,
}: let
  package =
    if stdenv.hostPlatform.isDarwin
    then
      writeShellScriptBin "google-chrome" ''
        app_path=$(mdfind 'kMDItemCFBundleIdentifier == "com.google.Chrome"' | head -1)
        if [ -z "$app_path" ]; then
          echo "error: Google Chrome not found" >&2
          exit 1
        fi
        exec "$app_path/Contents/MacOS/Google Chrome" "$@"
      ''
    else upstreamPackage;
in
  package.overrideAttrs (old: {
    passthru =
      (old.passthru or {})
      // {
        updateScript = null;
        maintenance = {
          source = "input";
          inputs = ["nixpkgs" "nixpkgs-stable"];
        };
      };
  })
