# Take passt from a master snapshot made after the 2026_03_21 tag, for four
# fixes nixpkgs' passt does not have:
#
# - TCP RST propagation to the socket side (cce94e92)
# - FIN retransmission and shutdown error checking (768baf42, e992b14b)
# - the inactivity timeout rewrite (e48ce41a, 1820103f)
#
# Together they repair IPv6 data forwarding from remote hosts (passt bug #183)
# and a rootless port-forwarding regression.
#
# nixpkgs is on passt 2025_09_19. Every attempt to bump it to a 2026 release so
# far has hung `nixosTests.podman`, which gates the nixos-unstable channel, and
# has been reverted. Drop this overlay once nixpkgs-unstable ships a passt at
# least as new as the pin below and that bump survives without a revert.
_: _: prev: {
  passt = prev.passt.overrideAttrs (_old: {
    version = "2026_03_21.bc872d91";
    src = prev.fetchgit {
      url = "https://passt.top/passt";
      rev = "bc872d91765dfd6ff34b0e9a34bce410fac1cef3";
      hash = "sha256-ZALBySy2c/3urOAe2BO2z9grbEKI7DJ3dYxqqB5jOXA=";
    };
  });
}
