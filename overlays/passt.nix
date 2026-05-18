# Pin passt to current master (bc872d91) to pick up fixes for:
# - TCP RST propagation to socket side (cce94e92)
# - FIN retransmission and shutdown error checking (768baf42, e992b14b)
# - Inactivity timeout rewrite (e48ce41a, 1820103f)
# These fix IPv6 data forwarding from remote hosts (passt bug #183) and a
# rootless port forwarding regression that blocked the 2026_01_20 tag from
# landing in nixpkgs.
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
