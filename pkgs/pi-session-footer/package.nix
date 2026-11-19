{
  callPackage,
  gitMinimal,
  pi,
  pi-pretty,
  pi-planning,
  pnpm_10,
}:
(callPackage ../build-support/pnpm-package.nix {}) {
  pname = "pi-session-footer";
  directory = ./.;
  pnpm = pnpm_10;
  dependencyHash = "sha256-nfQUhBj/9/3Llpq6VQe+3jI5n4yQ0nktzjta8vSsBPc=";
  environment = {
    PI_TEST_HOST = "${pi}/bin/pi";
    PI_TEST_PRETTY = "${pi-pretty}/${pi-pretty.packageRoot}";
    PI_TEST_PLANNING = "${pi-planning}/${pi-planning.packageRoot}";
  };

  nativeBuildInputs = [gitMinimal];
  __darwinAllowLocalNetworking = true;
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    node scripts/check-deployment.ts "$out/$packageRoot"
    runHook postInstallCheck
  '';
}
