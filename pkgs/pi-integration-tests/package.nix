{
  callPackage,
  pnpm_10,
}:
(callPackage ../build-support/pnpm-package.nix {}) {
  pname = "pi-integration-tests";
  directory = ./.;
  pnpm = pnpm_10;
  dependencyHash = "sha256-m7VT7/kmFPzlcfzWxQYSuDmDwXhoiH5mOyzYYr2a/TQ=";
}
