# Instantiate a specific nixpkgs revision and return its package set.
#
# Useful for temporarily pinning a single package to a known-good, cache-
# populated build while the channel we track catches up to a fix. Callers pick
# the attributes they need, e.g.:
#
#   inherit (import ../lib/nix/nixpkgs-at-rev.nix {
#     rev = "<40-char sha>";
#     hash = "sha256-...";   # of the GitHub archive tarball
#     inherit (prev.stdenv.hostPlatform) system;
#   }) somePackage;
{
  rev,
  hash,
  system,
}:
import (fetchTarball {
  url = "https://github.com/NixOS/nixpkgs/archive/${rev}.tar.gz";
  sha256 = hash;
}) {inherit system;}
