{
  upstreamPackage,
  lib,
}: let
  package =
    if lib.versionAtLeast upstreamPackage.version "6.0.0"
    then upstreamPackage
    else
      upstreamPackage.overrideAttrs (old: {
        patches = (old.patches or []) ++ [./0001-podman-healthcheck-run-add-ignore-result-flag.patch ./0002-healthcheck_linux-avoid-failing-transient-units.patch];
      });
in
  package.overrideAttrs (old: {
    passthru =
      (old.passthru or {})
      // {
        updateScript = null;
        tests = {};
        slowTests = (old.passthru.slowTests or {}) // (old.passthru.tests or {});
        maintenance = {
          source = "input";
          inputs = ["nixpkgs" "nixpkgs-stable"];
          temporary = true;
          retirement = "Remove the healthcheck backports when every channel provides Podman 6 or newer.";
        };
      };
  })
