# nodejs 26.9.0 added test-fs-cp-async-file-modes. The test sets the setuid,
# setgid and sticky bits with chmod, and the Linux build sandbox refuses those
# chmods with EPERM, so `make test-ci-js` fails and the build is reported as
# "builder failed with exit code 2".
#
# nixpkgs skips the test from this commit:
#
#   https://github.com/NixOS/nixpkgs/commit/fbc1eef4894df69b0fc0b8335cd2419f52d094f7
#
# The commit is on master but has not yet reached the nixpkgs-unstable channel
# that we track, so skip the same test here until a flake update brings the fix
# in.
_: _: prev:
prev.lib.optionalAttrs prev.stdenv.hostPlatform.isLinux {
  nodejs-slim_26 = prev.nodejs-slim_26.overrideAttrs (old: {
    checkFlags =
      map (
        flag:
          if prev.lib.hasPrefix "CI_SKIP_TESTS=" flag
          then flag + ",test-fs-cp-async-file-modes"
          else flag
      )
      old.checkFlags;
  });
}
