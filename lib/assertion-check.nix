{
  lib,
  pkgs,
}: {
  name,
  assertions,
  script ? ''touch "$out"'',
}:
lib.lazyDerivation {
  derivation = lib.asserts.checkAssertWarn assertions [] (pkgs.runCommandLocal name {} script);
  passthru.requiredSystemFeatures = [];
}
