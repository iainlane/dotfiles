# Local package overlay: any subdirectory of `pkgs/` containing a `package.nix`
# is exposed as `pkgs.<name>`, so a module uses a package defined in this
# repository the same way it uses one from nixpkgs.
{inputs}: let
  discovery = import ../lib/discovery.nix {inherit (inputs.nixpkgs) lib;};
  inherit (inputs.nixpkgs) lib;
  pkgsDir = ../pkgs;
  names = discovery.discoverPackages pkgsDir;
in
  final: _prev: let
    # A package can declare additional `callPackage` arguments in
    # `pkgs/<name>/args.nix`. That file takes `{inputs, final}` and returns the
    # arguments the package set cannot supply.
    extraArgs = name: let
      argsFile = pkgsDir + "/${name}/args.nix";
    in
      if builtins.pathExists argsFile
      then import argsFile {inherit final inputs;}
      else {};
  in
    {
      # Update-script generators the package definitions pull in via
      # callPackage. `flake.packages` is built from `names`, so this helper
      # stays internal to the package set.
      updaters = final.callPackage (pkgsDir + "/build-support/updaters.nix") {};
    }
    // lib.genAttrs names (
      name: final.callPackage (pkgsDir + "/${name}/package.nix") (extraArgs name)
    )
