# Temporarily pin mise on Darwin to the last cached aarch64-darwin build.
#
# Our nixpkgs has mise 2026.6.11, whose aarch64-darwin build fails in the Nix
# sandbox: the `oci::layer` setuid-preservation test runs there, but the sandbox
# strips setuid bits, so the assertion fails. nixpkgs skips that test on Linux
# only until this commit makes the skip apply on Darwin too:
#
#   https://github.com/NixOS/nixpkgs/commit/aa7d436d1a384d1df162f0cd94cba07d8fd36f3d
#
# It is on master but has not yet reached the nixpkgs-unstable channel we track,
# so building the Darwin closures compiles mise from source and fails. Until the
# channel advances to include that commit, take mise from the nixpkgs revision
# behind the last cached aarch64-darwin build (2026.6.5); it substitutes from
# cache.nixos.org instead of building. Drop this overlay once a flake update
# brings the fix. Linux is unaffected: it has the upstream-cached 2026.6.11.
_: _: prev:
prev.lib.optionalAttrs prev.stdenv.hostPlatform.isDarwin {
  inherit
    (import ../lib/nix/nixpkgs-at-rev.nix {
      rev = "baf9fac791ea8173567a01ac2b21c96806c63b05";
      hash = "sha256-nqDLAmYRohBcPUGZKf2aJ6SEYufqH9phohgPKUUCZwo=";
      inherit (prev.stdenv.hostPlatform) system;
    })
    mise
    ;
}
