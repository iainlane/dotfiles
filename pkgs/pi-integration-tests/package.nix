{
  callPackage,
  pnpm_10,
}:
(callPackage ../build-support/pnpm-package.nix {}) {
  pname = "pi-integration-tests";
  directory = ./.;
  pnpm = pnpm_10;
  dependencyHash = "sha256-V0nfxyAj4QFAzVFbDneFUQyrw7mP9IPPNgy2PK4vDcU=";
}
