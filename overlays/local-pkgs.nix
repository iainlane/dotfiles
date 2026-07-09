# Local package overlay: any subdirectory of `pkgs/` containing a `package.nix`
# is exposed as `pkgs.<name>`, so packages defined in this repository can be
# consumed from modules in the same way as nixpkgs can.
{inputs}: let
  helpers = import ../lib/helpers.nix {inherit inputs;};
  inherit (inputs.nixpkgs) lib;
  pkgsDir = ../pkgs;
  names = helpers.discoverPackages pkgsDir;
in
  final: _prev: let
    # `melange` pins a newer upstream than nixpkgs-stable carries and must be
    # built against the unstable `melange` derivation regardless of which
    # channel a host consumes. Everything else can callPackage unconditionally.
    nixpkgsUnstable = import inputs.nixpkgs {
      inherit (final.stdenv.hostPlatform) system;
      config.allowUnfree = true;
    };
    extraArgs = name:
      if name == "melange"
      then {inherit (nixpkgsUnstable) melange;}
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
