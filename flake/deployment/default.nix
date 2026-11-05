{
  inputs,
  lib,
  ...
}: let
  tools = import ./tools.nix {inherit inputs lib;};
in {
  perSystem = {
    pkgs,
    system,
    ...
  }: let
    args = {inherit pkgs system lib;};
  in {
    packages = tools.packages args;
    apps = tools.apps args;
    checks = import ./test.nix args;
  };
}
