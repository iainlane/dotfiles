{inputs, ...}: let
  nixbuild = import ./nixbuild-common.nix {inherit (inputs.nixpkgs) lib;};
in {
  flake.profiles.builder.os.darwin.systemManagerModule = {config, ...}: {
    imports = [
      nixbuild.module
    ];

    dotfiles.nix.binaryCaches."${nixbuild.builderAlias}" = nixbuild.binaryCaches."${nixbuild.builderAlias}";

    system.activationScripts.postActivation.text = ''
      mkdir -p ~/.ssh
      chmod 700 ~/.ssh
    '';

    environment.etc = {
      # Determinate Nix reads builders = @/etc/nix/machines by default.
      "nix/machines".text =
        nixbuild.machineLines [
          "x86_64-linux"
          "aarch64-linux"
          "armv7l-linux"
        ]
        config.sops.secrets.nixbuild-private-key.path;
    };
  };
}
