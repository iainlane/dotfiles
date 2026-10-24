{
  final,
  inputs,
}: let
  inherit (final) lib;
  system = final.stdenv.hostPlatform.system;
  unstablePhp = inputs.nixpkgs.legacyPackages.${system}.php84;
  firstFixedRelease = "8.4.27";
in {
  php84 = assert lib.assertMsg (lib.versionOlder unstablePhp.version firstFixedRelease) ''
    nixpkgs now provides PHP ${unstablePhp.version}, which includes the security
    fixes from ${firstFixedRelease}. Remove pkgs/larapaper/args.nix and
    flake/parts/checks/larapaper-php.nix.
  '';
    inputs.nixpkgs-stable.legacyPackages.${system}.php84;
}
