{inputs, ...}: {
  imports = [./settings.nix];

  perSystem.imports = [(import ./checks.nix {inherit inputs;})];
}
