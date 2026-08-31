{inputs}: _: prev: let
  lastReleaseBeforeGcrootFix = "3.2.0";
in {
  nix-direnv = assert prev.lib.assertMsg
  (!prev.lib.versionOlder lastReleaseBeforeGcrootFix prev.nix-direnv.version)
  ''
    nixpkgs now provides nix-direnv ${prev.nix-direnv.version}, which is newer
    than ${lastReleaseBeforeGcrootFix}. Remove the temporary nix-direnv input
    and this overlay so hosts use the packaged release.
  '';
    prev.callPackage inputs.nix-direnv {};
}
