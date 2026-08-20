{inputs, ...}: {
  perSystem = {pkgs, ...}: let
    promptConformance = import ../../../modules/ai/prompt-conformance {
      inherit inputs pkgs;
      inherit (pkgs) lib;
      inherit (pkgs.stdenv.hostPlatform) system;
    };
  in {
    checks.claude-prompt-conformance-codex-endpoint =
      promptConformance.tests.codexEndpoint;
  };
}
