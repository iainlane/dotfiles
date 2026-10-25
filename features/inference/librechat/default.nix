{
  config,
  featureResolver,
  ...
}: {
  dotfiles.flakeSystem.includes = [config.dotfiles.features.inference.librechat];

  dotfiles.features.inference.librechat = {
    checks = [
      ({pkgs, ...}: {inherit (pkgs) librechat-runtime;})
      (import ./home-manager-check.nix {
        inherit featureResolver;
        inherit (config.dotfiles) features modelCatalog;
      })
    ];
    homeManager = ./home-manager.nix;
    nixos = {username, ...}: {
      users.users.${username} = {
        linger = true;
        extraGroups = ["kvm"];
      };
    };
  };
}
