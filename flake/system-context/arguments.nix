{
  config,
  lib,
  flake-parts-lib,
  withSystem,
  ...
}: let
  flakeContexts = lib.genAttrs config.systems (system: withSystem system ({config, ...}: config.dotfiles.shared));
in {
  options.perSystem = flake-parts-lib.mkPerSystemOption {
    options.dotfiles.shared = lib.mkOption {
      type = lib.types.lazyAttrsOf lib.types.raw;
      default = {};
      description = ''
        Values to construct once per system and share with modules of every
        class. Modules read them as `flakeContext` for their own system and as
        `flakeContexts.''${system}` for another system.
      '';
    };
  };

  config = {
    _module.args = {inherit flakeContexts;};
    perSystem = {system, ...}: {
      _module.args = {
        inherit flakeContexts;
        flakeContext = flakeContexts.${system};
      };
    };
  };
}
