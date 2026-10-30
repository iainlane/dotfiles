{
  features,
  featureResolver,
}: {
  inputs,
  lib,
  pkgs,
  system,
  ...
}: let
  mkAssertionCheck = import ../../../../lib/assertion-check.nix {inherit lib pkgs;};
  darwin = pkgs.stdenv.hostPlatform.isDarwin;
  makeHome = frontend: let
    hostConfig = {
      name = "teamclaude-fixture";
      arch = pkgs.stdenv.hostPlatform.parsed.cpu.name;
      os =
        if darwin
        then "darwin"
        else "generic-linux";
      inherit system;
      homeDirectory = "/home/fixture";
      features = [
        (
          if frontend
          then features.ai.claude-code.teamclaude.frontend
          else features.ai.claude-code.teamclaude
        )
      ];
      excludes = [];
    };
  in
    inputs.home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules =
        featureResolver.resolveFeatures {
          class = "homeManager";
          inherit hostConfig;
        }
        ++ [
          ({lib, ...}: {
            options.dotfiles.claudeCode.package = lib.mkOption {
              type = lib.types.package;
              default = pkgs.claude-code;
            };
            config = {
              home = {
                username = "fixture";
                inherit (hostConfig) homeDirectory;
                stateVersion = "26.05";
              };
              dotfiles.claudeCode.teamclaude.frontend.account = "anthropic";
            };
          })
        ];
    };
  selected = (makeHome true).config;
  unselected = (makeHome false).config;
  enabled = config:
    if darwin
    then config.launchd.agents ? teamclaude-frontend
    else config.systemd.user.services ? teamclaude-frontend;
  cfg = selected.dotfiles.claudeCode.teamclaude;
  command =
    if darwin
    then selected.launchd.agents.teamclaude-frontend.config.ProgramArguments
    else lib.toList selected.systemd.user.services.teamclaude-frontend.Service.ExecStart;
in {
  teamclaude-frontend-config = mkAssertionCheck {
    name = "teamclaude-frontend-config";
    assertions = [
      {
        assertion = enabled selected && !(enabled unselected);
        message = "Only frontend selection may enable its user service";
      }
      {
        assertion = cfg.frontend.enable && !unselected.dotfiles.claudeCode.teamclaude.frontend.enable;
        message = "Frontend feature selection must set its Home Manager option";
      }
      {
        assertion = command == [(lib.getExe cfg.frontend.server)];
        message = "The frontend service must use the configured server";
      }
    ];
    script = ''
      ${lib.getExe pkgs.jq} -e \
        '.port == 3457 and .account == "anthropic" and .teamclaudeConfigFile == "/home/fixture/.config/teamclaude.json" and .stateDirectory == "/home/fixture/.local/state/claude-api-frontend"' \
        ${cfg.frontend.configFile}
      touch "$out"
    '';
  };
}
