# The pnpm dependency hash depends on the pnpm version and on nixpkgs' fetcher,
# so the pnpm tooling comes from unstable whichever channel the host consumes.
{
  final,
  inputs,
}: let
  unstable = inputs.nixpkgs.legacyPackages.${final.stdenv.hostPlatform.system};
in {
  inherit (unstable) fetchPnpmDeps pnpmConfigHook pnpm_10;
}
