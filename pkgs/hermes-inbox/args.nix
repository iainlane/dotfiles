{
  final,
  inputs,
}: {
  inherit (final) agentmail;
  hermesAgent = final.hermes-agent;
  hermesSource = inputs.hermes-agent;
  pkgs = final;
  pythonPackages = import ../../lib/hermes-python.nix {
    inherit inputs;
    inherit (final) lib;
    pkgs = final;
  };
}
