_: {
  perSystem = {
    lib,
    pkgs,
    ...
  }: {
    checks =
      lib.mapAttrs' (name: check: lib.nameValuePair "prose-lint-${name}" check)
      pkgs.prose-lint.passthru.tests;
  };
}
