{inputs}: final: _prev: {
  hermesPythonPackages = let
    agentPackage = inputs.hermes-agent.packages.${final.stdenv.hostPlatform.system}.default;
    python = agentPackage.python.override {
      packageOverrides = import ./hermes-python/overrides.nix {
        inherit (final) fetchpatch lib stdenv;
      };
      self = python;
    };
  in
    python.pkgs;
}
