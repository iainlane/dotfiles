{lib}: {
  path,
  pkgs,
  args,
}: let
  recipe = import path;
in
  if args ? upstreamPackage
  then recipe (lib.intersectAttrs (builtins.functionArgs recipe) (pkgs // args))
  else pkgs.callPackage path args
