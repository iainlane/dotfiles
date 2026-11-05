{
  pkgs,
  lib,
  ...
}: let
  tools = import ./tools.nix {
    inherit lib;
    inputs.system-manager.packages.x86_64-linux.default = pkgs.hello;
  };
  toolsFor = system: {
    apps = lib.attrNames (tools.apps {inherit system;});
    packages = lib.attrNames (tools.packages {
      inherit system;
      pkgs.nh = pkgs.hello;
    });
  };
  actual = lib.genAttrs ["aarch64-darwin" "x86_64-linux"] toolsFor;
  expected = {
    aarch64-darwin = {
      apps = [];
      packages = ["nh"];
    };
    x86_64-linux = {
      apps = ["system-manager"];
      packages = ["nh"];
    };
  };
in {
  deployment-tools = assert lib.assertMsg (actual == expected) "The operational tools differ from the expected configuration.";
    pkgs.runCommandLocal "deployment-tools" {} "touch $out";
}
