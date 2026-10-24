{
  inputs,
  lib,
  options,
  featureResolver,
  ...
}: {
  imports = [./schema.nix ./outputs.nix];
  perSystem = {
    pkgs,
    system,
    ...
  }: {
    checks = lib.mkMerge (map (check: check {inherit pkgs system;}) [
      (import ./checks/inventory.nix {inherit lib featureResolver;})
      (import ./checks/composition.nix {inherit lib featureResolver;})
      (import ./checks/resolution.nix {inherit inputs lib featureResolver;})
      (import ./checks/registration.nix {
        inherit lib featureResolver;
        definitions = options.dotfiles.features.definitionsWithLocations;
      })
      (import ./checks/outputs.nix {inherit inputs lib featureResolver;})
    ]);
  };
}
