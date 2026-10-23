{
  features,
  featureResolver,
}: {
  lib,
  inputs,
  pkgs,
  system,
  ...
}: let
  rea = import ./runtime.nix {inherit pkgs;};
  server = (import ./shared.nix {pkgs-unstable = pkgs;}).dotfiles.ai.mcpServers.rea;
  home = import ./home-manager.nix {pkgs-unstable = pkgs;};
  config = {
    catppuccin.accent = "mauve";
    dotfiles = {
      ai = {
        mcpServers.rea = server;
        skills = {};
        proseLint.enable = false;
      };
      claudeCode = {
        excludeMcpServers = [];
        excludeSkills = [];
        skills = {};
      };
      claudeDesktop.excludeMcpServers = [];
      codex.hooks = {};
      opencode2.cliConfig = {};
    };
    home.homeDirectory = "/home/fixture";
    xdg.configHome = "/home/fixture/.config";
  };
  args = {
    inherit config lib pkgs system;
    inherit inputs;
    mcp.excludeServers = names: servers: lib.removeAttrs servers names;
    instructions = {};
    outputStyles = {};
    skillTree = _: throw "REA registration must not evaluate skill assembly";
    defaultModels.openai = "fixture";
    modelCatalog = {};
    hostConfig.homeDirectory = config.home.homeDirectory;
  };
  apply = path: import path args;
  actual = {
    claude = (apply ../claude-code/home-manager.nix).config.programs.claude-code.mcpServers.rea;
    codex = (apply ../codex/system-config.nix).config.environment.etc."codex/config.toml".source.value.mcp_servers.rea;
    opencode = (apply ../opencode/home-manager.nix).config.programs.opencode.settings.mcp.rea;
    opencode2 = (apply ../opencode2/home-manager.nix).config.xdg.configFile."opencode2/opencode.json".source.value.mcp.servers.rea;
    copilot = (builtins.fromJSON (builtins.unsafeDiscardStringContext (apply ../copilot-cli/home-manager.nix).home.file.".copilot/mcp-config.json".source.text)).servers.rea;
    crush = (builtins.fromJSON (builtins.unsafeDiscardStringContext (apply ../crush/home-manager.nix).xdg.configFile."crush/crush.json".source.text)).mcp.rea;
    antigravity = (apply ../antigravity-cli/home-manager.nix).config.programs.antigravity-cli.mcpServers.rea;
    desktop =
      (builtins.fromJSON (builtins.unsafeDiscardStringContext
        (import ../claude-desktop/config-file.nix {
          inherit config lib pkgs;
          inherit (args) mcp;
        }).text)).mcpServers.rea;
    pi = (builtins.fromJSON (builtins.unsafeDiscardStringContext (apply ../pi/home-manager.nix).home.file.".pi/agent/mcp.json".text)).mcpServers.rea;
    cli = map toString home.home.packages;
    skill = home.dotfiles.ai.skills.reverse-engineer-anything;
    activation = home.home.activation or {};
    defaultHarnesses = lib.sort builtins.lessThan (lib.filter (name: lib.elem name ["ai.antigravity-cli" "ai.copilot-cli" "ai.crush" "ai.herdr" "ai.opencode" "ai.opencode2" "ai.pi" "ai.claude-code" "ai.codex"]) (featureResolver.featureNames {
      features = [features.ai];
      context = featureResolver.contextForSystem system;
    }));
    herdr = {
      homeManager = features.ai.herdr.homeManager != null;
      system = features.ai.herdr.system != null;
    };
  };
  stdio = server // {type = "stdio";};
  expected = {
    claude = stdio // {enabled = true;};
    codex = server // {enabled = true;};
    opencode = {
      type = "local";
      command = [server.command] ++ server.args;
      enabled = true;
    };
    opencode2 = {
      type = "local";
      command = [server.command] ++ server.args;
      disabled = false;
    };
    copilot = stdio // {tools = ["*"];};
    crush = stdio;
    antigravity = server;
    pi = server;
    desktop = server;
    cli = ["${rea}"];
    skill.directory = "${rea}/share/skills/rea/reverse-engineer-anything";
    activation = {};
    defaultHarnesses = lib.sort builtins.lessThan ["ai.antigravity-cli" "ai.copilot-cli" "ai.crush" "ai.herdr" "ai.opencode" "ai.opencode2" "ai.pi" "ai.claude-code" "ai.codex"];
    herdr = {
      homeManager = true;
      system = true;
    };
  };
in {
  rea-registration = assert lib.assertMsg (actual == expected) "REA CLI, skill and harness registrations differ from the configured runtime.";
    pkgs.runCommandLocal "rea-registration" {} ''
      touch "$out"
    '';
}
