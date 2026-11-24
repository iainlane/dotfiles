{
  callPackage,
  pnpm_10,
}:
(callPackage ../build-support/pnpm-package.nix {}) {
  pname = "pi-integration-tests";
  directory = ./.;
  pnpm = pnpm_10;
  dependencyHash = "sha256-/2hAogIotAGkYBuK4kIwI6T9PBo1PtEFx/Z2NyWXtRI=";
}
