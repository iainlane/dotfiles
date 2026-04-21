# Local package overlay: any subdirectory of `pkgs/` containing a `package.nix`
# is exposed as `pkgs.<name>`, so packages defined in this repository can be
# consumed from modules in the same way as nixpkgs can.
{inputs}: let
  helpers = import ../lib/helpers.nix {inherit inputs;};
  pkgsDir = ../pkgs;
  names = helpers.discoverPackages pkgsDir;
in
  final: _prev:
    inputs.nixpkgs.lib.genAttrs names (
      name: final.callPackage (pkgsDir + "/${name}/package.nix") {}
    )
