{inputs, ...}: let
  nixbuild = import ../../lib/nixbuild.nix {inherit (inputs.nixpkgs) lib;};
in {
  programs.ssh = nixbuild.sshProgramConfig;
}
