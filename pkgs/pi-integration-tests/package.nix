{
  callPackage,
  pnpm_10,
}:
(callPackage ../build-support/pnpm-package.nix {}) {
  pname = "pi-integration-tests";
  directory = ./.;
  pnpm = pnpm_10;
  dependencyHashes = {
    aarch64-darwin = "sha256-E83FpJq7vXIENKDIQsNBT6RTmc0KiJ+IBaleUy0sOE4=";
    aarch64-linux = "sha256-E83FpJq7vXIENKDIQsNBT6RTmc0KiJ+IBaleUy0sOE4=";
    x86_64-linux = "sha256-E83FpJq7vXIENKDIQsNBT6RTmc0KiJ+IBaleUy0sOE4=";
  };
}
