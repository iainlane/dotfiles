# Local package overlay: any subdirectory of `pkgs/` containing a `package.nix`
# is exposed as `pkgs.<name>`, so a module uses a package defined in this
# repository just as it uses one from nixpkgs.
{
  flakeContexts,
  inputs,
}: let
  discovery = import ../lib/discovery.nix {inherit (inputs.nixpkgs) lib;};
  inherit (inputs.nixpkgs) lib;
  npmPackages = import ../lib/npm-packages.nix {inherit lib;};
  pkgsDir = ../pkgs;
  callLocalPackage = import ../lib/local-package.nix {inherit lib;};
  names = discovery.discoverPackages pkgsDir;
in
  final: prev: let
    # Argument files can request inputs, final, prev and upstreamPackageSets.
    # Explicit upstream arguments use prev to avoid resolving the local
    # replacement.
    extraArgs = name: let
      argsFile = pkgsDir + "/${name}/args.nix";
      inherit (flakeContexts.${final.stdenv.hostPlatform.system}) upstreamPackageSets;
    in
      if builtins.pathExists argsFile
      then let arguments = import argsFile; in arguments (builtins.intersectAttrs (builtins.functionArgs arguments) {inherit final inputs prev upstreamPackageSets;})
      else {};
  in
    {
      # Update-script generators the package definitions pull in via
      # callPackage. `flake.packages` is built from `names`, so this helper
      # stays internal to the package set.
      updaters = final.callPackage (pkgsDir + "/build-support/updaters.nix") {};

      # The local packages that build npm packages, keyed by npm name. Every
      # channel takes them from the flake's own package set, which uses
      # nixpkgs-unstable. nixpkgs-stable's meta checks drop
      # `meta.identifiers.purlParts`, which records the npm name. The pnpm
      # dependency fetch also archives the tarballs' store paths, so its
      # fixed-output hash matches only when every channel uses the same
      # tarball derivations.
      localNpmPackages = let
        flakePackages = inputs.self.packages.${final.stdenv.hostPlatform.system} or {};
      in
        npmPackages.byName (lib.getAttrs (lib.intersectLists names (lib.attrNames flakePackages)) flakePackages);
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
