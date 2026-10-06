{
  inputs,
  lib,
  pkgs,
}: let
  agentPackage = inputs.hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default;
  interpreterArguments =
    lib.filter (lib.hasPrefix "python3")
    (lib.attrNames (lib.functionArgs agentPackage.override));

  python = pkgs.${lib.head interpreterArguments}.override {
    packageOverrides = import ./hermes-python-overrides.nix {
      inherit (pkgs) fetchpatch lib stdenv;
    };
    self = python;
  };
in
  if lib.length interpreterArguments == 1
  then python.pkgs
  else
    throw ''
      The hermes-agent package is expected to take one python3 interpreter
      argument, and takes ${toString (lib.length interpreterArguments)}.
    ''
