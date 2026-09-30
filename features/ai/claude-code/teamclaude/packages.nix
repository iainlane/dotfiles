# The programs that run Claude Code through TeamClaude. Their dependencies are
# function arguments, so the check in `flake/parts/checks/teamclaude.nix` can
# replace them with stand-ins.
{
  jq,
  lib,
  makeWrapper,
  symlinkJoin,
  writeShellApplication,
}: let
  # The scripts read the config file that the CLI uses: `TEAMCLAUDE_CONFIG`
  # when it is set, and `configFile` otherwise.
  setConfig = configFile: ''config=''${TEAMCLAUDE_CONFIG:-${lib.escapeShellArg configFile}}'';
in {
  # The `teamclaude` CLI, with `configFile` as its default config file. The
  # service watches that file, so the CLI must write accounts to it.
  cli = {
    teamclaude,
    configFile,
  }:
    symlinkJoin {
      inherit (teamclaude) pname version meta;
      paths = [teamclaude];
      nativeBuildInputs = [makeWrapper];
      postBuild = ''
        wrapProgram "$out/bin/teamclaude" \
          --set-default TEAMCLAUDE_CONFIG ${lib.escapeShellArg configFile}
      '';
    };

  # Starts the proxy server when the config lists at least one account. The
  # server exits with an error when it has no accounts, and the service manager
  # would then restart it every few seconds until the first `teamclaude login`.
  # This script exits successfully instead. The service watches the config file
  # and runs the script again when an account is added.
  server = {
    teamclaude,
    configFile,
  }:
    writeShellApplication {
      name = "teamclaude-server";

      runtimeInputs = [jq teamclaude];

      text = ''
        ${setConfig configFile}

        if [[ ! -e $config ]] || [[ $(jq '.accounts | length' "$config") == 0 ]]; then
          echo "$config lists no TeamClaude accounts. Add one with \`teamclaude login\`." >&2
          exit 0
        fi

        exec teamclaude server --headless
      '';
    };

  # A `claude` launcher. When the proxy is running, the launcher points Claude
  # Code at it; otherwise the launcher runs Claude Code unchanged. It keeps
  # Claude Code's `pname` and `version`, because Home Manager's module chooses
  # how to install plugins from the version.
  claude = {
    claudeCode,
    teamclaude,
    configFile,
  }: let
    launcher = writeShellApplication {
      name = "claude";

      runtimeInputs = [teamclaude];

      text = ''
        claude=${lib.escapeShellArg "${claudeCode}/bin/claude"}
        ${setConfig configFile}

        if [[ ! -e $config ]]; then
          exec "$claude" "$@"
        fi

        if ! exports=$(teamclaude env 2>/dev/null); then
          echo "claude: \`teamclaude env\` failed, so Claude Code is starting without the TeamClaude proxy. Run \`teamclaude env\` to see why." >&2
          exec "$claude" "$@"
        fi

        # The exports point Claude Code at the proxy's port on loopback.
        if [[ $exports =~ (127\.0\.0\.1|localhost):([0-9]+) ]] &&
          (: <"/dev/tcp/127.0.0.1/''${BASH_REMATCH[2]}") 2>/dev/null; then
          eval "$exports"
        else
          echo "claude: the TeamClaude proxy is not running, so Claude Code is starting without it. Run \`teamclaude status\` for details." >&2
        fi

        exec "$claude" "$@"
      '';
    };
  in
    symlinkJoin {
      inherit (claudeCode) pname version meta;
      # `symlinkJoin` links each file from the earliest path that has it. The
      # launcher is listed first so its `bin/claude` replaces Claude Code's.
      paths = [launcher claudeCode];
      passthru = claudeCode.passthru or {};
    };
}
