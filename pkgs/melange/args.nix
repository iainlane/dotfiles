# The override in `package.nix` moves melange to a version newer than
# nixpkgs-stable has, so it has to start from the unstable derivation whichever
# channel the host consumes.
{
  final,
  inputs,
}: {
  inherit (inputs.nixpkgs.legacyPackages.${final.stdenv.hostPlatform.system}) melange;
}
