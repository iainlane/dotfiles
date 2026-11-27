{
  callPackage,
  pnpm_10,
}:
(callPackage ../build-support/pnpm-package.nix {}) {
  pname = "pi-integration-tests";
  directory = ./.;
  pnpm = pnpm_10;
  dependencyHash = "sha256-apmfsnJXB/U3coYN/VLEaDAQegxTKnFv+0fwAqrHPe8=";
}
