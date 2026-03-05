{inputs}: _final: prev: {
  # Temporary: use the corepack expression from nixpkgs commit
  # d34b8b62c5b7333869593f2a2023a15c2725be54 (PR #496015) until this reaches
  # nixpkgs-unstable.
  corepack = prev.callPackage (inputs.nixpkgs-corepack + "/pkgs/by-name/co/corepack/package.nix") {};
}
