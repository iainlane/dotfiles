{inputs, ...}: {
  imports = [inputs.treefmt-nix.flakeModule];

  perSystem = {pkgs, ...}: {
    treefmt = import ./treefmt-config.nix {inherit pkgs;};
  };
}
