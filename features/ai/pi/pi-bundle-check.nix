{modelCatalog}: {
  inputs,
  pkgs,
  ...
}: let
  inherit (pkgs) lib;
  bundle = import ./bundle.nix {
    inherit inputs pkgs modelCatalog;
    mcp = import ../mcp-servers.nix {
      inherit inputs pkgs lib;
      servers = {};
      serverPackages = {};
    };
    mcpServers = {};
  };
  sharedSkills = inputs.home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    extraSpecialArgs = {
      inherit inputs;
      pkgs-unstable = pkgs;
    };
    modules = [
      ../skills.nix
      {
        home = {
          username = "pi-skills";
          homeDirectory = "/var/empty/pi-skills";
          stateVersion = "26.05";
        };
        dotfiles.ai.bundles = {};
        dotfiles.ai.skills.plain-technical-prose.skill.frontmatter.disable-model-invocation = true;
      }
    ];
  };
  probe = pkgs.writeShellScriptBin "pi" ''
    exec ${pkgs.python3}/bin/python ${./test/launcher.py} --probe "$@"
  '';
  launcher = import ./temporary.nix {
    inherit pkgs;
    package = probe;
    assets = bundle.previewAssets;
  };
in {
  pi-configured-launcher = assert sharedSkills.config.dotfiles.ai.skills.plain-technical-prose.skill.frontmatter.disable-model-invocation;
    pkgs.runCommandLocal "pi-configured-launcher" {} ''
      ${pkgs.python3}/bin/python ${./test/launcher.py} ${lib.getExe launcher} ${bundle.previewAssets} ${bundle.normalAssets}
      touch "$out"
    '';
}
