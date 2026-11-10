{
  upstreamPackage,
  channel,
  lib,
  updaters,
  python3,
  nix,
  git,
  writeShellApplication,
  runCommandLocal,
}: let
  source = lib.importJSON ./source.json;
  package = upstreamPackage.withPlugins {
    plugins = lib.mapAttrsToList (module: version: "${module}@${version}") source.plugins;
    hash = source.hashes.${channel};
  };
in
  package.overrideAttrs (old: {
    passthru =
      (old.passthru or {})
      // {
        maintenance = {
          source = "input";
          inputs = ["nixpkgs" "nixpkgs-stable"];
          localPins = ["plugins"];
          refresh = true;
        };
        updateScript = writeShellApplication {
          name = "update-caddy";
          runtimeInputs = [python3 nix git];
          text = ''exec python3 ${./update.py} "$@"'';
        };
        slowTests = (old.passthru.slowTests or {}) // (old.passthru.tests or {});
        tests = {
          updater = updaters.mkPythonUpdaterTest {
            pname = "caddy";
            script = ./update.py;
            test = ./test_update.py;
          };
          modules = runCommandLocal "caddy-modules" {nativeBuildInputs = [package];} ''
            caddy list-modules | grep -Fx dns.providers.cloudflare
            caddy list-modules | grep -Fx layer4.handlers.proxy
            printf '%s\n' '{"apps":{"http":{"servers":{"test":{"listen":["127.0.0.1:8443"],"automatic_https":{"disable":true},"routes":[{"handle":[{"handler":"static_response","body":"ok"}]}]}}}}}' >config.json
            HOME="$TMPDIR" caddy validate --config config.json
            touch "$out"
          '';
        };
      };
  })
