# Disable direnv tests on Darwin to work around fish being Killed: 9 during
# test-fish. The fish binary has broken Mach-O code signatures after nix
# store path rewriting.
#
# https://github.com/NixOS/nixpkgs/issues/507531
# https://github.com/NixOS/nix/issues/6065
_: _: prev:
prev.lib.optionalAttrs prev.stdenv.isDarwin {
  direnv = prev.direnv.overrideAttrs (_: {doCheck = false;});
}
