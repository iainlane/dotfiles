{inputs}: final: _prev: {
  mcpPythonPackages = let
    inherit (final) lib;
    pythonPackages = inputs.nixpkgs.legacyPackages.${final.stdenv.hostPlatform.system}.python314Packages;
    version = "2.3.0";
    usePackagedSdk = lib.versionAtLeast pythonPackages.mcp.version version && lib.versionOlder pythonPackages.mcp.version "3";
    src = final.fetchFromGitHub {
      owner = "modelcontextprotocol";
      repo = "python-sdk";
      tag = "v${version}";
      hash = "sha256-CnXi78zYxm0/R4fON/DzRYMSDYM/XM/9SE3s+Cf1BR0=";
    };
    blockbuster =
      if lib.versionAtLeast pythonPackages.blockbuster.version "1.5.27"
      then pythonPackages.blockbuster
      else
        pythonPackages.blockbuster.overridePythonAttrs (previous: {
          version = "1.5.27";
          src = final.fetchFromGitHub {
            owner = "cbornet";
            repo = "blockbuster";
            tag = "v1.5.27";
            hash = "sha256-r9UcyjBIZjnCxL/8RdMiGb5XiH0s8JnQ8fY9SIC4Hsw=";
          };
          nativeCheckInputs = previous.nativeCheckInputs ++ [pythonPackages.pytest-benchmark];
        });
    sdk = pythonFinal: _: {
      mcp =
        if usePackagedSdk
        then pythonPackages.mcp
        else
          (pythonFinal.callPackage (inputs.nixpkgs + "/pkgs/development/python-modules/mcp") {}).overridePythonAttrs (previous: {
            inherit version src;
            nativeCheckInputs = previous.nativeCheckInputs ++ [blockbuster];
            dontUsePytestXdist = true;
            pytestFlags = (previous.pytestFlags or []) ++ ["--numprocesses=2"];
          });
      mcp-types =
        if usePackagedSdk
        then pythonPackages.mcp-types
        else
          (pythonFinal.callPackage (inputs.nixpkgs + "/pkgs/development/python-modules/mcp-types") {}).overridePythonAttrs {
            inherit version src;
          };
    };
    fastmcp = import (inputs.mcp-nixos + "/nix/fastmcp4.nix") {inherit lib;};
  in
    pythonPackages.overrideScope (lib.composeExtensions sdk fastmcp);
}
