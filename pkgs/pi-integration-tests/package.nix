{
  callPackage,
  pnpm_10,
}:
(callPackage ../build-support/pnpm-package.nix {}) {
  pname = "pi-integration-tests";
  directory = ./.;
  pnpm = pnpm_10;
  dependencyHash = "sha256-E83FpJq7vXIENKDIQsNBT6RTmc0KiJ+IBaleUy0sOE4=";
}
