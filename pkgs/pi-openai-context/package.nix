{
  callPackage,
  pnpm_10,
}: let
  package = (callPackage ../build-support/pnpm-package.nix {}) {
    pname = "pi-openai-context";
    directory = ./.;
    pnpm = pnpm_10;
    dependencyHash = "sha256-cvGeyDzTuhSOTuGlSzK4NjuiMWtBD9ufzu7dL3GPd+s=";

    passthru.tests.integration = callPackage ./integration-test.nix {inherit package;};
    meta.description = "Apply ChatGPT account context windows to OpenAI models in Pi";
  };
in
  package
