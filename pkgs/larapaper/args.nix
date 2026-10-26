{
  final,
  inputs,
}: let
  inherit (final) lib;
  system = final.stdenv.hostPlatform.system;
in {
  php84 =
    if lib.versionOlder final.php84.version "8.4.27"
    then inputs.nixpkgs-stable.legacyPackages.${system}.php84
    else final.php84;
}
