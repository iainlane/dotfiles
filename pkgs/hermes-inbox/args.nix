{
  final,
  inputs,
}: {
  inherit (final) agentmail;
  hermesAgent = inputs.hermes-agent.packages.${final.stdenv.hostPlatform.system}.default;
  hermesSource = inputs.hermes-agent;
  pkgs = final;
  pythonPackages = import ../../lib/hermes-python.nix {
    inherit inputs;
    inherit (final) lib;
    pkgs = final;
  };
}
