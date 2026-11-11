{
  inputs,
  final,
  ...
}: {
  inherit (inputs.nixpkgs.legacyPackages.${final.stdenv.hostPlatform.system}) pnpm_10;
}
