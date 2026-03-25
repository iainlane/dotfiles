{
  inputs,
  lib,
  config,
  withSystem,
  helpers,
  username,
  overlays,
  nixpkgsConfig,
}: hostname: hostConfig: let
  sshKeyFile = inputs.secrets + "/${hostConfig.hostname}/user-ssh-key.yaml";
  hasSshKey = builtins.pathExists sshKeyFile;
  result = withSystem hostConfig.system (
    {pkgs, ...}: {
      homeSpecialArgs = {
        pkgs-unstable = pkgs;
      };
      systemConfig = inputs.system-manager.lib.makeSystemConfig {
        inherit overlays;
        modules =
          [
            ./system.nix
            inputs.sops-nix.nixosModules.sops
            config.flake.nix.substitutersModule
          ]
          ++ helpers.mkModules {
            moduleType = "systemManagerModule";
            inherit hostConfig;
            inherit (config.flake) profiles;
          }
          ++ lib.optional (hostConfig.systemModule != null) hostConfig.systemModule;
        extraSpecialArgs = {
          inherit
            inputs
            hostname
            hostConfig
            username
            nixpkgsConfig
            ;
        };
      };
    }
  );
in {
  homeBaseDir = "/home";
  systemSuffix = "linux";
  extraHomeModules = [
    {
      nix.gc = {
        automatic = true;
        dates = "weekly";
        options = "--delete-older-than 30d";
      };
    }
    {
      sops.age.keyFile = "${hostConfig.homeDirectory}/.config/sops/age/keys.txt";
    }
    (lib.mkIf hasSshKey {
      sops.secrets.ssh-private-key = {
        sopsFile = sshKeyFile;
        path = "${hostConfig.homeDirectory}/.ssh/id_ed25519";
      };
    })
  ];
  inherit (result) homeSpecialArgs systemConfig;
}
