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

  frontend = pkgs.writeShellScriptBin "claude-api-frontend" ''
    ${lib.getExe pkgs.jq} --null-input '$ARGS.positional' --args -- "$@" >"$FRONTEND_RESULT"
    exit "''${FRONTEND_STATUS:-0}"
  '';

  frontendClaudeCode =
    (pkgs.writeShellScriptBin "claude" ''
      exec ${lib.getExe pkgs.jq} --null-input \
        '{args: $ARGS.positional, env: {HTTPS_PROXY: env.HTTPS_PROXY, HTTP_PROXY: env.HTTP_PROXY, https_proxy: env.https_proxy, http_proxy: env.http_proxy, NO_PROXY: env.NO_PROXY, no_proxy: env.no_proxy, NODE_EXTRA_CA_CERTS: env.NODE_EXTRA_CA_CERTS, ANTHROPIC_BASE_URL: env.ANTHROPIC_BASE_URL}}' \
        --args -- "$@" >"$CLAUDE_RESULT"
    '')
    // {inherit (claudeCode) pname version;};

  frontendLauncher = packages.claude {
    inherit teamclaude configFile;
    claudeCode = frontendClaudeCode;
    frontend = {
      package = frontend;
      configFile = "/fixture/frontend.json";
      port = 3457;
      caFile = "/fixture/authority/ca.pem";
    };
  };
in {
  teamclaude = assert lib.assertMsg (lib.getVersion claude == claudeCode.version)
  "The Claude Code launcher must keep Claude Code's version, which Home Manager reads";
    provisioner.overrideAttrs {
      pname = "teamclaude-check";
      __darwinAllowLocalNetworking = true;
      TEAMCLAUDE_TEST_CLAUDE = lib.getExe' claude "claude";
      TEAMCLAUDE_TEST_SERVER = lib.getExe server;
      TEAMCLAUDE_TEST_FRONTEND = lib.getExe' frontendLauncher "claude";
    };
}
