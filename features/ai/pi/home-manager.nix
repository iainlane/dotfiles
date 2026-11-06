{
  pkgs,
  lib,
  config,
  defaultModels,
  inputs,
  instructions,
  mcp,
  modelCatalog,
  skillRuntimePackages ? null,
  ...
}: let
  permissionConfig = import ./permission-config.nix {inherit pkgs;};
  defaults = import ../skill-defaults.nix {
    inherit inputs;
    inherit (pkgs) lib;
  };
  bundle = import ./bundle.nix {
    inherit pkgs inputs defaultModels instructions mcp modelCatalog skillRuntimePackages;
    accent = config.catppuccin.accent;
    mcpServers = config.dotfiles.ai.mcpServers;
    proseLintEnabled = config.dotfiles.ai.proseLint.enable;
    proseLintOwners = config.dotfiles.ai.proseLint.owners or ["iainlane" "underwhelmingperformance"];
    skills = config.dotfiles.ai.skills or defaults.skills;
    skillRuntimeDependencies = config.dotfiles.ai.skillRuntimeDependencies or defaults.runtimeDependencies;
  };
  isCollection = path: builtins.any (name: path == ".pi/agent/${name}" || pkgs.lib.hasPrefix ".pi/agent/${name}/" path) (builtins.attrNames bundle.collections);
  rootFiles = pkgs.lib.filterAttrs (path: _: !isCollection path) bundle.normalFiles.home.file;
  collectionFiles = pkgs.lib.mapAttrs' (name: source:
    pkgs.lib.nameValuePair ".pi/agent/${name}" {
      inherit source;
      recursive = true;
      ignorelinks = true;
    })
  bundle.collections;
in {
  inherit (bundle.normalFiles) xdg;
  home = {
    packages = [bundle.package];
    activation.piPermissionConfig = lib.hm.dag.entryAfter ["linkGeneration"] ''
      previousConfig=
      if [[ -n "''${oldGenPath:-}" ]]; then
        previousConfig="$oldGenPath/home-files/.pi/agent/extensions/pi-permission-system/config.json"
      fi
      run ${lib.getExe permissionConfig} \
        "$HOME/.pi/agent/extensions/pi-permission-system/config.json" "$previousConfig"
    '';

    file = rootFiles // collectionFiles;
  };
}
