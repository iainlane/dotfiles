{inputs, ...}: let
  nixbuild = import ../../lib/nixbuild.nix {inherit (inputs.nixpkgs) lib;};
in {
  system.activationScripts.postActivation.text = ''
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh
  '';

  programs.ssh = nixbuild.sshProgramConfig;
}
