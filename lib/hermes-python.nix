{
  inputs,
  pkgs,
}: let
  agentPackage = inputs.hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default;
  python = agentPackage.python.override {
    packageOverrides = import ./hermes-python-overrides.nix {
      inherit (pkgs) fetchpatch lib stdenv;
    };
    self = python;
  };
in
  python.pkgs
