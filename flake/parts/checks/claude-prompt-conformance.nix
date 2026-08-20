{inputs, ...}: {
  perSystem = {pkgs, ...}: let
    promptConformance = import ../../../modules/ai/prompt-conformance {
      inherit inputs pkgs;
      inherit (pkgs) lib;
      inherit (pkgs.stdenv.hostPlatform) system;
    };
  in {
    checks.claude-prompt-conformance = promptConformance.tests.conformance;
  };
}
