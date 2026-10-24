{inputs, ...}: {
  imports = [inputs.treefmt-nix.flakeModule];

  perSystem = {pkgs, ...}: {
    treefmt = (import ./configuration.nix {inherit pkgs;}) // {flakeCheck = false;};
  };
}
