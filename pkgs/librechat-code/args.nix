{
  inputs,
  final,
}: {
  bun2nix = inputs.bun2nix.packages.${final.stdenv.hostPlatform.system}.default;
  bun = final.callPackage ./bun-runtime.nix {};
}
