{
  config,
  featureResolver,
  ...
}: {
  dotfiles.features.ai.t3code = {
    checks = ./checks.nix;
    homeManager = {
      hostConfig,
      pkgs-unstable,
      ...
    }: {
      home.packages = [
        (import ./package.nix {
          pkgs = pkgs-unstable;
          desktop = featureResolver.hasFeature hostConfig config.dotfiles.features.desktop;
        })
      ];
    };
  };
}
