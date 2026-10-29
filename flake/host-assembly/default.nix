{
  config,
  inputs,
  lib,
  hostResults,
  ...
}: {
  imports = [./assembly.nix];
  perSystem = {
    pkgs,
    system,
    ...
  }: {
    checks =
      import ./checks/evaluation.nix {
        inherit lib hostResults;
        inherit (config.dotfiles) hosts username;
        hostMetadata = config.flake.hosts;
      }
      {inherit pkgs system;}
      // import ./checks/home-configuration.nix {inherit inputs lib;} {inherit pkgs;};
  };
}
