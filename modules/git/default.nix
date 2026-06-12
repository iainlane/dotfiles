# Modules are exported as paths so that several profiles can include this
# module and have the module system deduplicate the imports.
{
  flake.modules.git = {
    homeManagerModules = [./home-manager.nix];
    os = {
      darwin.homeManagerModules = [./credential-darwin.nix];
      linux.homeManagerModules = [./credential-linux.nix ./gitsign.nix];
      nixos.homeManagerModules = [./credential-linux.nix ./gitsign.nix];
    };
  };
}
