# The Lua grammar is cross-compiled to WASI. nixpkgs-stable's wasi32 toolchain
# links it against a non-PIC wasilibc and fails, so take the cross package set
# from unstable whichever channel the host consumes.
{
  final,
  inputs,
}: {
  inherit (inputs.nixpkgs.legacyPackages.${final.stdenv.hostPlatform.system}) pkgsCross;
}
