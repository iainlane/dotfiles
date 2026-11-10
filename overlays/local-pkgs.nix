# Local package overlay: any subdirectory of `pkgs/` containing a `package.nix`
# is exposed as `pkgs.<name>`, so a module uses a package defined in this
# repository just as it uses one from nixpkgs.
{inputs}: let
  discovery = import ../lib/discovery.nix {inherit (inputs.nixpkgs) lib;};
  inherit (inputs.nixpkgs) lib;
  npmPackages = import ../lib/npm-packages.nix {inherit lib;};
  pkgsDir = ../pkgs;
  callLocalPackage = import ../lib/local-package.nix {inherit lib;};
  names = discovery.discoverPackages pkgsDir;
in
  final: prev: let
    # Argument files can request inputs, final and prev. Explicit upstream
    # arguments use prev to avoid resolving the local replacement.
    extraArgs = name: let
      argsFile = pkgsDir + "/${name}/args.nix";
    in
      if builtins.pathExists argsFile
      then let arguments = import argsFile; in arguments (builtins.intersectAttrs (builtins.functionArgs arguments) {inherit final inputs prev;})
      else {};
  in
    {
      # Update-script generators the package definitions pull in via
      # callPackage. `flake.packages` is built from `names`, so this helper
      # stays internal to the package set.
      updaters = final.callPackage (pkgsDir + "/build-support/updaters.nix") {};

      # The local packages that build npm packages, keyed by npm name.
      # nixpkgs-stable's meta checks drop `meta.identifiers.purlParts`, so the
      # names come from the flake's own package set, built with
      # nixpkgs-unstable. The packages come from this package set.
      localNpmPackages =
        lib.mapAttrs (_: attribute: final.${attribute})
        (npmPackages.attributesByName (
          lib.getAttrs
          (lib.intersectLists names (lib.attrNames (inputs.self.packages.${final.stdenv.hostPlatform.system} or {})))
          inputs.self.packages.${final.stdenv.hostPlatform.system}
        ));
    }
    // lib.genAttrs names (
      name: let
        package = callLocalPackage {
          path = pkgsDir + "/${name}/package.nix";
          pkgs = final;
          args = extraArgs name;
        };
        updater = package.updateScript or null;
      in
        if package ? maintenance || updater == null || !(updater ? maintenance)
        then package
        else package.overrideAttrs (old: {passthru = (old.passthru or {}) // {inherit (updater) maintenance;};})
    )
