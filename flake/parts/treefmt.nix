{inputs, ...}: {
  imports = [inputs.treefmt-nix.flakeModule];

  perSystem = {config, ...}: let
    inherit (config._module.args) pkgs;
  in {
    treefmt = import ./treefmt-config.nix {inherit pkgs;};
  };
}
