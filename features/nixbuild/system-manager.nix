{inputs, ...}: let
  nixbuild = import ../../lib/nixbuild.nix {inherit (inputs.nixpkgs) lib;};
in {
  environment.etc = nixbuild.systemManagerSshConfig;
}
