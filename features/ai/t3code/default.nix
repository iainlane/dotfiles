{
  config,
  featureResolver,
  ...
}: let
  inherit (config.dotfiles) features;
in {
  dotfiles.features.ai.t3code = {
    checks = ./checks.nix;
    homeManager = {
      config,
      hostConfig,
      pkgs-unstable,
      ...
    }: {
      home.packages = [
        (import ./package.nix {
          pkgs = pkgs-unstable;
          desktop = featureResolver.hasFeature hostConfig features.desktop;
          t3Home = "${config.xdg.configHome}/t3";
        })
      ];
    };
  };
}
