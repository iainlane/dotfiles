# The override in `package.nix` moves melange to a version newer than
# nixpkgs-stable has, so it has to start from the unstable derivation whichever
# channel the host consumes. The Go builder comes from unstable too: stable's
# `buildGoLatestModule` can lag behind the toolchain melange's `go.mod` needs.
{upstreamPackageSets}: let
  unstable = upstreamPackageSets.nixpkgs;
in {
  upstreamPackage = unstable.melange;
  inherit (unstable) buildGoLatestModule;
}
