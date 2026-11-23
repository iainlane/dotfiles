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
  lensConfig = builtins.fromJSON (builtins.unsafeDiscardStringContext bundle.normalFiles.home.file.".pi-lens/config.json".text);
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
  assert lensConfig.lsp.serverOverrides.nix.command
  == [
    (lib.getExe pkgs.nixd)
    "--nixpkgs-expr=import ${inputs.nixpkgs.outPath} {}"
    ''--nixos-options-expr=(import ${inputs.nixpkgs.outPath}/nixos/lib/eval-config.nix { system = "${pkgs.stdenv.hostPlatform.parsed.cpu.name}-linux"; modules = []; }).options''
  ];
  assert !lensConfig.ui.compactLspStatus;
    pkgs.runCommandLocal "pi-configured-launcher" {} ''
      ${pkgs.python3}/bin/python ${./test/launcher.py} ${lib.getExe launcher} ${bundle.previewAssets} ${bundle.normalAssets}
      touch "$out"
    '';
}
