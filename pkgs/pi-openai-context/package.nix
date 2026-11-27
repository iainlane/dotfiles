{
  callPackage,
  pnpm_10,
}: let
  package = (callPackage ../build-support/pnpm-package.nix {}) {
    pname = "pi-openai-context";
    directory = ./.;
    pnpm = pnpm_10;
    dependencyHash = "sha256-x319SU+MB+C7Mtjoc+s2jjQmfqqL8whUwLwHap1Zesg=";

    passthru.tests.integration = callPackage ./integration-test.nix {inherit package;};
    meta.description = "Apply ChatGPT account context windows to OpenAI models in Pi";
  };
in
  package
