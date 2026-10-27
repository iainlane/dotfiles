{
  inputs,
  lib,
  pkgs,
  ...
}: let
  registry = import ./mcp-server-definitions.nix {inherit inputs pkgs;};
  server = registry.serverPackages.nixos;
  python = server.pythonPackages.python.withPackages (_: [server.pythonPackages.mcp]);
in {
  mcp-server-protocol =
    pkgs.runCommandLocal "mcp-server-protocol" {
      nativeBuildInputs = [python pkgs.basedpyright pkgs.ruff];
      __darwinAllowLocalNetworking = true;
      SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    } ''
      export HOME="$TMPDIR"
      ruff check ${./mcp-server.test.py}
      ruff format --check ${./mcp-server.test.py}
      basedpyright ${./mcp-server.test.py}
      python ${./mcp-server.test.py} \
        ${lib.getExe server} ${lib.getExe registry.serverPackages.git} \
        ${lib.getExe pkgs.mcp-proxy}
      touch "$out"
    '';
}
