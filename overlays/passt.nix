# Take passt from a master snapshot for four fixes that are missing from passt
# releases before 2026_05_07:
#
# - TCP RST propagation to the socket side (cce94e92)
# - FIN retransmission and shutdown error checking (768baf42, e992b14b)
# - the inactivity timeout rewrite (e48ce41a, 1820103f)
#
# Together they repair IPv6 data forwarding from remote hosts (passt bug #183)
# and a rootless port-forwarding regression.
#
# The snapshot replaces passt only in a package set whose passt is older than
# 2026_05_07. Evaluating passt fails once nixpkgs-stable has a release at least
# that new, because no host needs the overlay after that.
{inputs}: _: prev: let
  inherit (prev) lib;

  firstFixedRelease = "2026_05_07";

  stablePasst = inputs.nixpkgs-stable.legacyPackages.${prev.stdenv.hostPlatform.system}.passt;
in {
  passt = assert lib.assertMsg (lib.versionOlder stablePasst.version firstFixedRelease) ''
    nixpkgs-stable now provides passt ${stablePasst.version}, which includes
    the fixes from ${firstFixedRelease}. Remove overlays/passt.nix.
  '';
    if lib.versionOlder prev.passt.version firstFixedRelease
    then
      prev.passt.overrideAttrs (_old: {
        version = "2026_03_21.bc872d91";
        src = prev.fetchgit {
          url = "https://passt.top/passt";
          rev = "bc872d91765dfd6ff34b0e9a34bce410fac1cef3";
          hash = "sha256-ZALBySy2c/3urOAe2BO2z9grbEKI7DJ3dYxqqB5jOXA=";
        };
      })
    else prev.passt;
}
