{inputs, ...}: {
  helpers = import ./helpers.nix {inherit inputs;};
  netboot = import ./netboot {inherit inputs;};
}
