{
  callPackage,
  pnpm_10,
}:
(callPackage ../build-support/pnpm-package.nix {}) {
  pname = "pi-integration-tests";
  directory = ./.;
  pnpm = pnpm_10;
  dependencyHash = "sha256-h42LIw+eqXc3lCRpYlZ1U70XTO2wqx9yrhLlKr8XJJY=";
}
