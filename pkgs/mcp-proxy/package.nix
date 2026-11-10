{
  upstreamPackage,
  python3Packages,
  lib,
}: let
  package =
    if upstreamPackage.version == "0.13.0" && lib.versionAtLeast python3Packages.mcp.version "2"
    then upstreamPackage.override {python3Packages = python3Packages.overrideScope (_: previous: {mcp = previous.mcp_1;});}
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
          temporary = true;
          retirement = "Remove the SDK selection once both channels package MCP proxy with the required SDK.";
        };
      };
  })
