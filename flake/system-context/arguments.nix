{
  config,
  lib,
  withSystem,
  ...
}: let
  flakeContexts = lib.genAttrs config.systems (system: withSystem system (args: args));
in {
  _module.args = {inherit flakeContexts;};
  perSystem = {system, ...}: {
    _module.args = {
      inherit flakeContexts;
      flakeContext = flakeContexts.${system};
    };
  };
}
