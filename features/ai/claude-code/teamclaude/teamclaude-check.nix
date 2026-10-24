{pkgs, ...}: let
  inherit (pkgs) lib;

  teamclaudeDir = ./.;
  packages = pkgs.callPackage (teamclaudeDir + "/packages.nix") {};
  provisioner = pkgs.callPackage ./provisioner/package.nix {};

  # The test sets `TEAMCLAUDE_CONFIG`, so the scripts never read this path.
  configFile = "/nonexistent/teamclaude.json";

  claudeCode =
    pkgs.writeShellScriptBin "claude" ''
      exec ${lib.getExe pkgs.jq} --null-input \
        '{args: $ARGS.positional, httpsProxy: env.HTTPS_PROXY, caFile: env.NODE_EXTRA_CA_CERTS}' \
        --args -- "$@" >"$CLAUDE_RESULT"
    ''
    // {
      pname = "claude-code";
      version = "2.1.999";
    };

  teamclaude = pkgs.writeShellScriptBin "teamclaude" ''
    exec ${lib.getExe pkgs.jq} --null-input '$ARGS.positional' --args -- "$@" >"$TEAMCLAUDE_RESULT"
  '';

  claude = packages.claude {
    inherit claudeCode configFile;
    teamclaude = packages.cli {
      inherit configFile;
      inherit (pkgs) teamclaude;
    };
  };

  server = packages.server {inherit teamclaude configFile;};
in {
  teamclaude = assert lib.assertMsg (lib.getVersion claude == claudeCode.version)
  "The Claude Code launcher must keep Claude Code's version, which Home Manager reads";
    provisioner.overrideAttrs {
      pname = "teamclaude-check";
      __darwinAllowLocalNetworking = true;
      TEAMCLAUDE_TEST_CLAUDE = lib.getExe' claude "claude";
      TEAMCLAUDE_TEST_SERVER = lib.getExe server;
    };
}
