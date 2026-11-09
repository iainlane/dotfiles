{
  lib,
  pkgs,
  system,
  ...
}: let
  fixture = (pkgs.writeShellScriptBin "opencode2" ''
    printf '%s\n' 'OpenCode 2' "$@"
  '').overrideAttrs {version = "2.0.0";};

  home = import ./home-manager.nix {
    inherit lib pkgs system;
    config = {};
    inputs.llm-agents.packages.${system}.opencode2 = fixture;
    instructions.concatenated = "";
    mcp.wrapWithTools = {
      package,
      binName,
      ...
    }:
      assert binName == "opencode"; package;
  };

  package = home.config.programs.opencode.package;
  actual = {
    inherit (package) pname version;
    inherit (package.meta) mainProgram;
  };
  expected = {
    pname = "opencode";
    version = "2.0.0";
    mainProgram = "opencode";
  };
in {
  opencode-command = assert lib.assertMsg (actual == expected) "OpenCode must expose the v2 package as opencode.";
    pkgs.runCommandLocal "opencode-command-test" {} ''
      test ! -e ${package}/bin/opencode2
      printf '%s\n' 'OpenCode 2' 'argument with spaces' --flag > expected
      ${lib.getExe package} 'argument with spaces' --flag > actual
      diff -u expected actual
      touch "$out"
    '';
}
