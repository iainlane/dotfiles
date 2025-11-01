{
  pkgs,
  inputs,
  system,
}: {
  # Formatter used by conform for Nix files.
  inherit (pkgs) alejandra;

  # LazyVim ansible extra adds this Mason tool. We provide it via Nix.
  ansible-lint = builtins.getAttr "ansible-lint" pkgs;

  # Rust diagnostics tooling (used by rustaceanvim configuration).
  bacon = inputs.bacon.defaultPackage.${system};
  bacon-ls = inputs.bacon-ls.defaultPackage.${system};

  # HTML formatter used by Mason tooling integration.
  inherit (pkgs.rubyPackages) htmlbeautifier;
}
