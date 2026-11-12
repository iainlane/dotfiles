{
  final,
  upstreamPackageSets,
}: let
  inherit (final) lib;
in {
  php84 =
    if lib.versionOlder final.php84.version "8.4.27"
    then upstreamPackageSets.nixpkgs-stable.php84
    else final.php84;
}
