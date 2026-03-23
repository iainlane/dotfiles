# melange — build APKs from source code.
# To update: ./modules/melange/update.sh
_: let
  homeManagerModule = {pkgs-unstable, ...}: {
    home.packages = [
      (pkgs-unstable.callPackage ./package.nix {})
    ];
  };
in {
  flake.modules.melange.homeManagerModules = [homeManagerModule];
}
